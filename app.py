import os
import oracledb
import json
import hashlib
from flask import Flask, request, jsonify, render_template, session, Response
from werkzeug.utils import secure_filename

app = Flask(__name__)
app.secret_key = os.urandom(24)
app.config['MAX_CONTENT_LENGTH'] = 5 * 1024 * 1024 

# --- Database Connection ---
DB_USER = "PUZZLEGAME"
DB_PASSWORD = "qwertylf1"
DB_DSN = "localhost:1521/XEPDB1"
pool = oracledb.create_pool(user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN, min=2, max=5, increment=1)

def get_db_connection():
    # Gets a connection from the pool
    return pool.acquire()

@app.route('/')
def index():
    # Serves the main HTML file
    return render_template('index.html')

# --- Auth Endpoints ---
@app.route('/api/auth/register', methods=['POST'])
def register():
    # Handles new user registration
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
    # Handles user login
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
    # Clears the user session
    session.clear()
    return jsonify({"success": True})

@app.route('/api/auth/status', methods=['GET'])
def status():
    # Checks if a user is currently logged in
    if 'user_id' in session:
        return jsonify({"isLoggedIn": True, "user": {"id": session['user_id'], "name": session['username']}})
    return jsonify({"isLoggedIn": False})

# --- УНИВЕРСАЛЬНЫЙ ОБРАБОТЧИК ИГРОВЫХ ДЕЙСТВИЙ ---
@app.route('/api/action', methods=['POST'])
def handle_action():
    # A single endpoint to handle all in-game and data-related actions
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
        game_session_id = session.get('game_session_id')

        if action == 'start':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.start_new_game', oracledb.DB_TYPE_CLOB,
                [user_id, params.get('size'), params.get('difficulty'),
                 params.get('gameMode'), params.get('imageUrl'),
                 params.get('isDailyChallenge'), params.get('forceNew'),
                 params.get('replayGameId')])
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
            
        elif action == 'hint':
            result = cursor.callfunc('GAME_MANAGER_PKG.get_hint', str, [game_session_id])
            return result, 200, {'Content-Type': 'application/json'}
            
        elif action == 'get_leaderboards':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.get_leaderboards', oracledb.DB_TYPE_CLOB, [params.get('size', 0), params.get('difficulty', 0)])

        elif action == 'get_game_history':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.get_game_history', oracledb.DB_TYPE_CLOB, [user_id])
        
        elif action == 'get_default_images':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.get_default_images', oracledb.DB_TYPE_CLOB)

        elif action == 'get_user_images':
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.get_user_images', oracledb.DB_TYPE_CLOB, [user_id])

        elif action == 'delete_image':
            image_id_to_delete = params.get('imageId')
            if image_id_to_delete:
                cursor.callproc('GAME_MANAGER_PKG.delete_user_image', [user_id, image_id_to_delete])
                return jsonify({"success": True, "message": "Image deleted"})
            
        else:
            return jsonify({"error": "Unknown action"}), 400

        return result_clob.read(), 200, {'Content-Type': 'application/json'}

    finally:
        cursor.close()
        pool.release(conn)

# --- Image Handling Endpoints (BLOBs) ---
@app.route('/api/upload-image', methods=['POST'])
def upload_image():
    if 'user_id' not in session: return jsonify({'error': 'Not authorized'}), 401
    if 'image' not in request.files: return jsonify({'error': 'No file part'}), 400
    file = request.files['image']
    if file.filename == '': return jsonify({'error': 'No selected file'}), 400

    if file:
        image_data = file.read()
        mime_type = file.mimetype
        # file_name больше не нужен
        image_hash = hashlib.sha256(image_data).hexdigest()
        
        conn = get_db_connection()
        cursor = conn.cursor()
        try:
            # Вызываем функцию с 4 параметрами, убрав file_name
            result = cursor.callfunc(
                'GAME_MANAGER_PKG.save_user_image', 
                int, 
                [session['user_id'], mime_type, image_data, image_hash] # <-- Убрали file_name
            )
            
            if result == 1:
                return jsonify({'success': True, 'status': 'uploaded'})
            elif result == 0:
                return jsonify({'success': True, 'status': 'duplicate'})
            elif result == 2:
                return jsonify({'success': False, 'error': 'Достигнут лимит в 7 картинок.'})

        finally:
            cursor.close()
            pool.release(conn)
        
    return jsonify({'error': 'File upload failed'}), 500

@app.route('/api/image/<int:image_id>')
def get_image_data(image_id):
    # Замечание: user_id здесь не используется для проверки прав,
    # так как стандартные картинки должны быть доступны всем.
    # Проверка прав для пользовательских картинок может быть добавлена позже.
    
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
            # Если стандартная картинка не найдена (ORA-01403: no data found), то это не ошибка.
            # Мы просто перейдем к попытке №2.
            err_obj, = e.args
            if err_obj.code != 1403:
                # Если ошибка другая, выводим её в консоль
                print(f"Oracle Error trying to get default image: {e}")

        # Попытка №2: Получить картинку как ПОЛЬЗОВАТЕЛЬСКУЮ
        # Эта часть сработает, если попытка №1 не вернула результат
        try:
            # Сбрасываем переменные перед вторым вызовом
            mime_type_var.setvalue(0, "")
            image_data_var.setvalue(0, None)

            # Для пользовательских картинок может потребоваться проверка user_id
            user_id_for_check = session.get('user_id', -1) 
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