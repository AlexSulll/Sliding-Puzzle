# =============================================================================
# Файл: app.py
# Версия: Адаптированная
# Описание: Flask-сервер для игры "Пятнашки".
# =============================================================================

import os
import oracledb
import json
import hashlib
from flask import Flask, request, jsonify, render_template, session, Response

app = Flask(__name__)
app.secret_key = os.urandom(24)
app.config['MAX_CONTENT_LENGTH'] = 5 * 1024 * 1024 
ALLOWED_EXTENSIONS = {'png', 'jpg', 'jpeg'}

def allowed_file(filename):
    return '.' in filename and \
           filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

# --- Подключение к базе данных ---
# Замените на ваши учетные данные, если они отличаются
DB_USER = "PUZZLEGAME"
DB_PASSWORD = "qwertylf1"
DB_DSN = "localhost:1521/XEPDB1"
pool = oracledb.create_pool(user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN, min=2, max=5, increment=1)

def get_db_connection():
    # Получает соединение из пула
    return pool.acquire()

@app.route('/')
def index():
    # Отдает главную HTML-страницу
    return render_template('index.html')

# --- Эндпоинты авторизации ---
@app.route('/api/auth/register', methods=['POST'])
def register():
    # Обработка регистрации нового пользователя
    data = request.json
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        user_id = cursor.callfunc('GAME_MANAGER_PKG.register_user', int, [data.get('username'), data.get('passwordHash')])
        if user_id == -1:
            return jsonify({"success": False, "message": "Пользователь с таким именем уже существует."}), 409
        session['user_id'] = user_id
        session['username'] = data.get('username')
        return jsonify({"success": True, "user": {"id": user_id, "name": data.get('username')}})
    finally:
        cursor.close()
        pool.release(conn)

@app.route('/api/auth/login', methods=['POST'])
def login():
    # Обработка входа пользователя
    data = request.json
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        user_id = cursor.callfunc('GAME_MANAGER_PKG.login_user', int, [data.get('username'), data.get('passwordHash')])
        if user_id > 0:
            session['user_id'] = user_id
            session['username'] = data.get('username')
            return jsonify({"success": True, "user": {"id": user_id, "name": data.get('username')}})
        else:
            return jsonify({"success": False, "message": "Неверное имя пользователя или пароль."}), 401
    finally:
        cursor.close()
        pool.release(conn)

@app.route('/api/auth/logout', methods=['POST'])
def logout():
    # Очистка сессии пользователя
    session.clear()
    return jsonify({"success": True})

@app.route('/api/auth/status', methods=['GET'])
def status():
    # Проверка, авторизован ли пользователь
    if 'user_id' in session:
        return jsonify({"isLoggedIn": True, "user": {"id": session['user_id'], "name": session['username']}})
    return jsonify({"isLoggedIn": False})

# --- Универсальный обработчик игровых действий ---
@app.route('/api/action', methods=['POST'])
def handle_action():
    # Единый эндпоинт для всех игровых и связанных с данными действий
    if 'user_id' not in session and request.json.get('action') not in ['get_default_images']:
        return jsonify({"error": "Пользователь не авторизован"}), 401

    data = request.json
    action = data.get('action')
    params = data.get('params', {})
    
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        result_clob = None
        user_id = session.get('user_id')
        game_session_id = session.get('game_session_id') or params.get('sessionId')

        if action == 'start':
            # --- НАЧАЛО ИЗМЕНЕНИЯ ---
            # Преобразуем URL картинки в ID перед вызовом пакета
            image_url = params.get('imageUrl')
            image_id = None
            if image_url and isinstance(image_url, str):
                try:
                    # Извлекаем ID из конца URL, например, из '/api/image/123'
                    image_id = int(image_url.split('/')[-1])
                except (ValueError, IndexError):
                    image_id = None # Если URL не в том формате, ID будет NULL
            
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.start_new_game', oracledb.DB_TYPE_CLOB,
                [
                    user_id,
                    params.get('size'),
                    params.get('difficulty'),
                    params.get('gameMode'),
                    image_id, # Передаем числовой ID вместо URL
                    params.get('isDailyChallenge'),
                    params.get('forceNew'),
                    params.get('replayGameId')
                ]
            )
            # --- КОНЕЦ ИЗМЕНЕНИЯ ---
            
            game_data = json.loads(result_clob.read())
            if game_data.get('sessionId'):
                session['game_session_id'] = game_data.get('sessionId')
            return jsonify(game_data)

        elif action == 'move':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.process_move', oracledb.DB_TYPE_CLOB, [game_session_id, params.get('tile')])
        
        elif action == 'undo':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.undo_move', oracledb.DB_TYPE_CLOB, [game_session_id])
        
        elif action == 'redo':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.redo_move', oracledb.DB_TYPE_CLOB, [game_session_id])
        
        elif action == 'abandon':
            cursor.callproc('GAME_MANAGER_PKG.abandon_game', [game_session_id])
            session.pop('game_session_id', None)
            return jsonify({"success": True})
        
        elif action == 'timeout':
            cursor.callproc('GAME_MANAGER_PKG.timeout_game', [game_session_id])
            session.pop('game_session_id', None)
            return jsonify({"success": True})
        
        elif action == 'hint':
            # callfunc возвращает строку, которую нужно вернуть как JSON
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

        elif action == 'get_user_stats':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.get_user_stats', oracledb.DB_TYPE_CLOB, [user_id])
            
        elif action == 'delete_image':
            image_id_to_delete = params.get('imageId')
            if image_id_to_delete:
                cursor.callproc('GAME_MANAGER_PKG.delete_user_image', [user_id, int(image_id_to_delete)])
                return jsonify({"success": True, "message": "Image deleted"})
        
        elif action == 'restart':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.restart_game', oracledb.DB_TYPE_CLOB, [game_session_id])
            
        else:
            return jsonify({"error": "Unknown action"}), 400

        # Для всех остальных действий, возвращающих CLOB
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
        
        conn = get_db_connection()
        cursor = conn.cursor()
        try:
            result = cursor.callfunc(
                'GAME_MANAGER_PKG.save_user_image', 
                int, 
                [session['user_id'], mime_type, image_data, image_hash]
            )
            
            if result == 1:
                return jsonify({'success': True, 'status': 'uploaded'})
            elif result == 0:
                return jsonify({'success': True, 'status': 'duplicate'})
            elif result == 2:
                return jsonify({'success': False, 'error': 'Достигнут лимит в 7 картинок.'})
            else:
                return jsonify({'error': 'Unknown error during image save'}), 500

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
        
        # Попытка №1: Получить картинку как СТАНДАРТНУЮ
        try:
            cursor.callproc("GAME_MANAGER_PKG.get_default_image_data", [image_id, mime_type_var, image_data_var])
            image_bytes_lob = image_data_var.getvalue()
            if image_bytes_lob and image_bytes_lob.size() > 0:
                return Response(image_bytes_lob.read(), mimetype=mime_type_var.getvalue())
        except oracledb.Error as e:
            err_obj, = e.args
            if err_obj.code != 1403: # 1403 = "no data found", это ожидаемо
                print(f"Oracle Error trying to get default image: {e}")

        # Попытка №2: Получить картинку как ПОЛЬЗОВАТЕЛЬСКУЮ
        try:
            mime_type_var.setvalue(0, "")
            image_data_var.setvalue(0, None)

            cursor.callproc("GAME_MANAGER_PKG.get_user_image_data", [image_id, mime_type_var, image_data_var])
            
            image_bytes_lob = image_data_var.getvalue()
            if image_bytes_lob and image_bytes_lob.size() > 0:
                return Response(image_bytes_lob.read(), mimetype=mime_type_var.getvalue())
        except oracledb.Error as e:
            err_obj, = e.args
            if err_obj.code != 1403:
                print(f"Oracle Error trying to get user image: {e}")

        # Если обе попытки не увенчались успехом
        return "Image not found", 404
            
    finally:
        cursor.close()
        pool.release(conn)

@app.errorhandler(413)
def request_entity_too_large(error):
    return jsonify({"success": False, "error": "Файл слишком большой. Максимальный размер - 5 МБ."}), 413

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)