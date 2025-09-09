import os
import oracledb
import hashlib
import mimetypes

# --- НАСТРОЙКИ ПОДКЛЮЧЕНИЯ К БАЗЕ ДАННЫХ ---
# (скопируйте их из вашего файла app.py)
DB_USER = "PUZZLEGAME"
DB_PASSWORD = "qwertylf1"
DB_DSN = "localhost:1521/XEPDB1"

# --- НАСТРОЙКИ СКРИПТА ---
# Папка, в которую вы положили стандартные картинки
IMAGE_DIR = "default_images"

def load_default_images():
    """
    Скрипт для одноразовой загрузки стандартных изображений в БД.
    Изображения добавляются в таблицу USER_IMAGES с USER_ID = NULL.
    Скрипт можно безопасно запускать несколько раз, дубликаты не создадутся.
    """
    if not os.path.exists(IMAGE_DIR):
        print(f"Ошибка: Папка '{IMAGE_DIR}' не найдена.")
        return

    try:
        with oracledb.connect(user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN) as connection:
            with connection.cursor() as cursor:
                print("Подключение к базе данных успешно.")
                
                for filename in os.listdir(IMAGE_DIR):
                    file_path = os.path.join(IMAGE_DIR, filename)
                    if os.path.isfile(file_path):
                        try:
                            # Читаем файл как бинарные данные
                            with open(file_path, 'rb') as f:
                                image_data = f.read()

                            # Вычисляем хеш
                            image_hash = hashlib.sha256(image_data).hexdigest()
                            # Определяем MIME-тип
                            mime_type, _ = mimetypes.guess_type(file_path)
                            if mime_type is None:
                                mime_type = 'application/octet-stream'

                            print(f"Обработка файла: {filename}...")

                            # Используем MERGE для безопасной вставки (избегаем дубликатов)
                            # Он вставит запись, только если картинки с таким именем и USER_ID IS NULL еще нет
                            sql_merge = """
                                MERGE INTO user_images t
                                USING (SELECT :name AS image_name FROM dual) s
                                ON (t.image_name = s.image_name AND t.user_id IS NULL)
                                WHEN NOT MATCHED THEN
                                    INSERT (user_id, mime_type, image_data, image_name, image_hash)
                                    VALUES (NULL, :mime, :data, :name, :hash)
                            """
                            
                            cursor.execute(sql_merge, {
                                'name': filename,
                                'mime': mime_type,
                                'data': image_data,
                                'hash': image_hash
                            })
                            
                            # Проверяем, была ли вставка
                            if cursor.rowcount > 0:
                                print(f"  > Успешно добавлено: {filename}")
                            else:
                                print(f"  > Пропущено (уже существует): {filename}")

                        except Exception as e:
                            print(f"  > Ошибка при обработке файла {filename}: {e}")
                
                connection.commit()
                print("\nЗагрузка стандартных картинок завершена.")

    except oracledb.Error as e:
        print(f"Ошибка подключения к базе данных: {e}")

if __name__ == '__main__':
    load_default_images()