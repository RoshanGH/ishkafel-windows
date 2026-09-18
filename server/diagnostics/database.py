"""生产使用 MySQL；SQLite 仅用于无外部依赖的本地契约测试。"""
from contextlib import contextmanager
import sqlite3


class MysqlConnection:
    def __init__(self, connection):
        self.connection = connection

    def execute(self, statement, args=()):
        cursor = self.connection.cursor()
        if statement == 'BEGIN IMMEDIATE':
            self.connection.begin()
            # 所有入库事务通过单行锁串行检查配额/幂等，避免并发竞态。
            cursor.execute('SELECT id FROM report_lock WHERE id=1 FOR UPDATE')
        else:
            cursor.execute(statement.replace('?', '%s'), args)
        return cursor


@contextmanager
def connect_database(path, mysql):
    if mysql:
        import pymysql
        raw = pymysql.connect(**mysql, charset='utf8mb4', autocommit=False,
                              connect_timeout=10, read_timeout=30, write_timeout=30)
        connection = MysqlConnection(raw)
    else:
        raw = sqlite3.connect(path, timeout=10)
        connection = raw
    try:
        yield connection
        raw.commit()
    except Exception:
        raw.rollback()
        raise
    finally:
        raw.close()
