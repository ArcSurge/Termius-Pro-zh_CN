# -*- coding: utf-8 -*-
import logging

# 定义 3 字符固定长度的级别缩写
LEVEL_NAMES = {
    'DEBUG': 'DBG',
    'INFO': 'INF',
    'WARNING': 'WRN',
    'ERROR': 'ERR',
    'CRITICAL': 'CRT'
}


class CustomFormatter(logging.Formatter):
    """自定义日志格式化器，使用缩写的级别名称"""

    def format(self, record):
        record.levelname = LEVEL_NAMES.get(record.levelname, record.levelname)
        return super().format(record)


def setup_logging(log_level='INFO'):
    """配置日志系统"""
    handler = logging.StreamHandler()
    handler.setFormatter(CustomFormatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S"))

    logger = logging.getLogger()
    logger.setLevel(log_level)
    logger.handlers.clear()
    logger.addHandler(handler)
