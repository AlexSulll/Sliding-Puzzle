import os
import oracledb
import json
import hashlib
from flask import Flask, request, jsonify, render_template, session, Response
from werkzeug.utils import secure_filename # <-- ДОБАВИТЬ
import uuid # <-- ДОБАВИТЬ

app = Flask(__name__)
app.secret_key = os.urandom(24)
app.config['MAX_CONTENT_LENGTH'] = 5 * 1024 * 1024
app.config['UPLOAD_FOLDER'] = os.path.join('static', 'uploads')
ALLOWED_EXTENSIONS = {'png', 'jpg', 'jpeg'}

os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

def allowed_file(filename):
    return '.' in filename and \
           filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

# --- Подключение к базе данных ---
DB_USER = "PUZZLEGAME"
DB_PASSWORD = "qwertylf1"
DB_DSN = "localhost:1521/XEPDB1"
pool = oracledb.create_pool(user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN, min=2, max=5, increment=1)

def get_db_connection():
    return pool.acquire()

@app.route('/')
def index():
    return render_template('index.html')

# --- Эндпоинты авторизации ---
@app.route('/api/auth/register', methods=['POST'])
def register():
    # ИЗМЕНЕНО: Логика формирования JSON перенесена в БД.
    # Python теперь только вызывает функцию и устанавливает сессию при успехе.
    data = request.json
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        result_clob = cursor.callfunc('GAME_MANAGER_PKG.register_user', oracledb.DB_TYPE_CLOB, [data.get('username'), data.get('passwordHash')])
        result_json = json.loads(result_clob.read())
        
        if result_json.get('success'):
            session['user_id'] = result_json['user']['id']
            session['username'] = result_json['user']['name']
            
        return jsonify(result_json)
    finally:
        cursor.close()
        pool.release(conn)

@app.route('/api/auth/login', methods=['POST'])
def login():
    # ИЗМЕНЕНО: Логика формирования JSON перенесена в БД.
    # Python теперь только вызывает функцию и устанавливает сессию при успехе.
    data = request.json
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        result_clob = cursor.callfunc('GAME_MANAGER_PKG.login_user', oracledb.DB_TYPE_CLOB, [data.get('username'), data.get('passwordHash')])
        result_json = json.loads(result_clob.read())
        
        if result_json.get('success'):
            session['user_id'] = result_json['user']['id']
            session['username'] = result_json['user']['name']

        return jsonify(result_json)
    finally:
        cursor.close()
        pool.release(conn)

@app.route('/api/auth/logout', methods=['POST'])
def logout():
    # НЕ ИЗМЕНЕНО: Логика сессии остается в Python.
    session.clear()
    return jsonify({"success": True})

@app.route('/api/auth/status', methods=['GET'])
def status():
    # НЕ ИЗМЕНЕНО: Логика сессии остается в Python.
    if 'user_id' in session:
        return jsonify({"isLoggedIn": True, "user": {"id": session['user_id'], "name": session['username']}})
    return jsonify({"isLoggedIn": False})

# --- Универсальный обработчик игровых действий ---
@app.route('/api/action', methods=['POST'])
def handle_action():
    if 'user_id' not in session and request.json.get('action') not in ['get_default_images']:
        return jsonify({"error": "Пользователь не авторизован"}), 401

    data = request.json
    action = data.get('action')
    params = data.get('params', {})
    
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        if 'user_id' in session:
            cursor.callproc('GAME_MANAGER_PKG.update_last_seen', [session.get('user_id')])
            
        result_clob = None
        user_id = session.get('user_id')
        game_session_id = session.get('game_session_id') or params.get('sessionId')

        if action == 'start':
            image_id = params.get('imageId')
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.start_new_game', oracledb.DB_TYPE_CLOB,
                [
                    user_id,
                    params.get('size'),
                    params.get('difficulty'),
                    params.get('gameMode'),
                    image_id, # <-- Теперь здесь всегда будет правильный ID или None
                    params.get('isDailyChallenge'),
                    params.get('forceNew'),
                    params.get('replayGameId')
                ]
            )
            game_data = json.loads(result_clob.read())
            image_url = game_data.get('imageUrl')
            if game_data.get('gameMode') == 'IMAGE' and image_url and image_url.startswith('/uploads/'):
                filename = os.path.basename(image_url)
                filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)
                if not os.path.exists(filepath):
                    game_data['imageMissing'] = True
                    
            if game_data.get('sessionId'):
                session['game_session_id'] = game_data.get('sessionId')
            return jsonify(game_data)

        elif action == 'move':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.process_move', oracledb.DB_TYPE_CLOB, [game_session_id, params.get('tile')])
        
        elif action == 'undo':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.undo_move', oracledb.DB_TYPE_CLOB, [game_session_id])
        
        elif action == 'redo':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.redo_move', oracledb.DB_TYPE_CLOB, [game_session_id])
        
        # ИЗМЕНЕНО: abandon_game теперь функция, возвращающая JSON.
        elif action == 'abandon':
            result_json_str = cursor.callfunc('GAME_MANAGER_PKG.abandon_game', str, [game_session_id])
            session.pop('game_session_id', None)
            return result_json_str, 200, {'Content-Type': 'application/json'}
        
        # ИЗМЕНЕНО: timeout_game теперь функция (хотя в пакете ее еще нужно будет поменять с процедуры).
        elif action == 'timeout':
            # Предполагаем, что timeout_game тоже станет функцией
            cursor.callproc('GAME_MANAGER_PKG.timeout_game', [game_session_id]) # Пока оставим callproc, если не меняли
            session.pop('game_session_id', None)
            return jsonify({"success": True}) # или возвращаем результат callfunc
        
        elif action == 'hint':
            result_json_str = cursor.callfunc('GAME_MANAGER_PKG.get_hint', str, [game_session_id])
            return result_json_str, 200, {'Content-Type': 'application/json'}
            
        elif action == 'get_leaderboards':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.get_leaderboards', oracledb.DB_TYPE_CLOB, [params.get('size', 0), params.get('difficulty', 0)])

        elif action == 'get_game_history':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.get_game_history', oracledb.DB_TYPE_CLOB, [user_id])
        
        elif action == 'get_default_images':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.get_default_images', oracledb.DB_TYPE_CLOB)

        elif action == 'get_user_images':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.get_user_images', oracledb.DB_TYPE_CLOB, [user_id])
            images_from_db = json.loads(result_clob.read())
    
            valid_images = []
            for image in images_from_db:
                filename = os.path.basename(image['path'])
                filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)

                if os.path.exists(filepath):
                    valid_images.append(image)
    
            return jsonify(valid_images)

        elif action == 'get_user_stats':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.get_user_stats', oracledb.DB_TYPE_CLOB, [user_id])
            
        # ИЗМЕНЕНО: delete_image теперь функция, возвращающая JSON.
        elif action == 'delete_image':
            image_id_to_delete = params.get('imageId')
            if image_id_to_delete:
                result_json_str = cursor.callfunc('GAME_MANAGER_PKG.delete_user_image', str, [user_id, int(image_id_to_delete)])
                return result_json_str, 200, {'Content-Type': 'application/json'}
        
        elif action == 'restart':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.restart_game', oracledb.DB_TYPE_CLOB, [game_session_id])
            
        elif action == 'get_daily_leaderboard':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.get_daily_leaderboard', oracledb.DB_TYPE_CLOB)
                        
        else:
            return jsonify({"error": "Unknown action"}), 400

        return result_clob.read(), 200, {'Content-Type': 'application/json'}

    finally:
        if cursor:
            cursor.close()
        if conn:
            pool.release(conn)

# --- Эндпоинты для работы с изображениями (BLOB) ---
@app.route('/api/upload-image', methods=['POST'])
def upload_image():
    if 'user_id' not in session: return jsonify({'error': 'Not authorized'}), 401
    if 'image' not in request.files: return jsonify({'error': 'No file part'}), 400
    file = request.files['image']
    if file.filename == '': return jsonify({'error': 'No selected file'}), 400

    if file and allowed_file(file.filename):
        image_data = file.read()
        mime_type = file.mimetype
        image_hash = hashlib.sha256(image_data).hexdigest().upper()

        # Создаем безопасное и уникальное имя файла
        filename = secure_filename(file.filename)
        unique_filename = f"{uuid.uuid4().hex}_{filename}"
        
        # Сохраняем файл на сервере
        file_save_path = os.path.join(app.config['UPLOAD_FOLDER'], unique_filename)
        with open(file_save_path, "wb") as f:
            f.write(image_data)
            
        # Этот путь будет сохранен в БД
        path_for_db = f"/uploads/{unique_filename}"

        conn = get_db_connection()
        cursor = conn.cursor()
        try:
            # Вызываем измененную функцию из пакета
            result_json_str = cursor.callfunc(
                'GAME_MANAGER_PKG.save_user_image', 
                str, 
                [session['user_id'], mime_type, path_for_db, image_hash]
            )
            return result_json_str, 200, {'Content-Type': 'application/json'}
        finally:
            cursor.close()
            pool.release(conn)
                
    return jsonify({'success': False, 'error': 'Недопустимый тип файла. Разрешены только JPG и PNG.'}), 400

@app.route('/api/image/<int:image_id>')
def get_image_data(image_id):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        mime_type_var = cursor.var(str)
        image_data_var = cursor.var(oracledb.DB_TYPE_BLOB)
        
        # Вызываем процедуру ТОЛЬКО для стандартных изображений
        cursor.callproc("GAME_MANAGER_PKG.get_default_image_data", [image_id, mime_type_var, image_data_var])
        
        image_bytes_lob = image_data_var.getvalue()
        if image_bytes_lob and image_bytes_lob.size() > 0:
            return Response(image_bytes_lob.read(), mimetype=mime_type_var.getvalue())
        
        # Если ничего не найдено
        return "Image not found", 404
            
    finally:
        cursor.close()
        pool.release(conn)

@app.errorhandler(413)
def request_entity_too_large(error):
    return jsonify({"success": False, "error": "Файл слишком большой. Максимальный размер - 5 МБ."}), 413


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)