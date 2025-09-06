import os
import oracledb
import json
from flask import Flask, request, jsonify, render_template, session
from werkzeug.utils import secure_filename

app = Flask(__name__)
app.secret_key = os.urandom(24)
app.config['UPLOAD_FOLDER'] = os.path.join(app.static_folder, 'uploads')
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

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

@app.route('/api/auth/guest', methods=['POST'])
def login_as_guest():
    # Handles guest login, creating a temporary guest user if needed
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        if 'guest_user_id' in session:
            user_id = session['guest_user_id']
            cursor.execute("SELECT USERNAME FROM USERS WHERE USER_ID = :1", [user_id])
            username_row = cursor.fetchone()
            username = username_row[0] if username_row else 'Guest'
        else:
            user_id = cursor.callfunc('GAME_MANAGER_PKG.create_guest_user', int)
            session['guest_user_id'] = user_id
            username = f'guest_{user_id}'

        session['user_id'] = user_id
        session['username'] = username
        
        return jsonify({"success": True, "user": {"id": user_id, "name": username}})
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

# --- UNIVERSAL ACTION HANDLER FOR THE GAME ---
@app.route('/api/action', methods=['POST'])
def handle_action():
    # A single endpoint to handle all in-game actions
    if 'user_id' not in session:
        return jsonify({"error": "Пользователь не авторизован"}), 401

    data = request.json
    action = data.get('action')
    params = data.get('params', {})
    
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        result_clob = None

        if action == 'start':
            # Starts a new game
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.start_new_game', oracledb.DB_TYPE_CLOB,
                [session['user_id'], params.get('size'), params.get('difficulty'),
                 params.get('gameMode'), params.get('imageUrl'),
                 params.get('isDailyChallenge'), params.get('forceNew')])
            game_data = json.loads(result_clob.read())
            if game_data.get('sessionId'):
                session['game_session_id'] = game_data.get('sessionId')
            return jsonify(game_data)

        elif action == 'move':
            # Processes a player's move
            session_id = session.get('game_session_id')
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.process_move', oracledb.DB_TYPE_CLOB, [session_id, params.get('tile')])
        
        elif action == 'undo':
            # Undoes the last move
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.undo_move', oracledb.DB_TYPE_CLOB, [session.get('game_session_id')])
        
        elif action == 'redo':
            # Redoes the last undone move
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.redo_move', oracledb.DB_TYPE_CLOB, [session.get('game_session_id')])
        
        elif action == 'abandon':
            # Abandons the current game
            cursor.callproc('GAME_MANAGER_PKG.abandon_game', [session.get('game_session_id')])
            session.pop('game_session_id', None)
            return jsonify({"success": True})
            
        elif action == 'hint':
            # Gets a hint for the next move
            result = cursor.callfunc('GAME_MANAGER_PKG.get_hint', str, [session.get('game_session_id')])
            return result, 200, {'Content-Type': 'application/json'}
            
        elif action == 'get_leaderboards':
            # Fetches the leaderboards with optional filters
            result_clob = cursor.callfunc('GAME_MANAGER_PKG.get_leaderboards', oracledb.DB_TYPE_CLOB, [params.get('size', 0), params.get('difficulty', 0)])

        else:
            return jsonify({"error": "Unknown action"}), 400

        # Return the result from the database as JSON
        return result_clob.read(), 200, {'Content-Type': 'application/json'}

    finally:
        cursor.close()
        pool.release(conn)

# --- Image Upload Endpoint ---
@app.route('/api/upload-image', methods=['POST'])
def upload_image():
    # Handles user image uploads for the picture mode
    if 'image' not in request.files:
        return jsonify({'error': 'No file part'}), 400
    file = request.files['image']
    if file.filename == '':
        return jsonify({'error': 'No selected file'}), 400
    if file:
        filename = secure_filename(file.filename)
        save_path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        file.save(save_path)
        return jsonify({'imageUrl': f'/static/uploads/{filename}'})
    return jsonify({'error': 'File upload failed'}), 500

if __name__ == '__main__':
    # Runs the Flask application, making it accessible on the local network
    app.run(host='0.0.0.0', port=5000, debug=True)

