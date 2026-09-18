"""由每日定时任务调用；仅删除本服务超过保留期的报告。"""
import os
import time
from database import connect_database


def main():
    mysql = dict(host=os.environ.get('REPORT_MYSQL_HOST', '127.0.0.1'),
                 port=int(os.environ.get('REPORT_MYSQL_PORT', '3306')),
                 user=os.environ['REPORT_MYSQL_USER'], password=os.environ['REPORT_MYSQL_PASSWORD'],
                 database=os.environ['REPORT_MYSQL_DATABASE'])
    with connect_database('', mysql) as db:
        cursor = db.execute('DELETE FROM reports WHERE received < ?', (time.time() - 30 * 86400,))
        print('expired_reports_removed={}'.format(cursor.rowcount))


if __name__ == '__main__':
    main()
