#!/usr/bin/env python3
"""
WeChat 4.x 文件系统监控工具
监控 WeChat 数据目录的变化，检测消息撤回事件

用法: python3 Scripts/fsmonitor.py
"""

import os
import sys
import time
import json
import hashlib
import sqlite3
from datetime import datetime
from pathlib import Path

# WeChat 数据目录
WECHAT_CONTAINER = os.path.expanduser(
    "~/Library/Containers/com.tencent.xinWeChat/Data/Documents"
)
XWECHAT_FILES = os.path.join(WECHAT_CONTAINER, "xwechat_files")

# 日志文件
LOG_FILE = "/tmp/wechat_fsmonitor.log"

def log(msg):
    """写入日志"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] {msg}"
    print(line)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")

def get_user_dirs():
    """获取所有用户数据目录"""
    if not os.path.exists(XWECHAT_FILES):
        return []
    return [
        d for d in os.listdir(XWECHAT_FILES)
        if os.path.isdir(os.path.join(XWECHAT_FILES, d))
        and d not in ("all_users", "Backup")
    ]

def get_db_files(user_dir):
    """获取用户的数据库文件列表"""
    db_storage = os.path.join(XWECHAT_FILES, user_dir, "db_storage")
    if not os.path.exists(db_storage):
        return []
    
    db_files = []
    for root, dirs, files in os.walk(db_storage):
        for f in files:
            if f.endswith(".db") and not f.endswith("-shm") and not f.endswith("-wal"):
                db_files.append(os.path.join(root, f))
    return db_files

def get_file_info(filepath):
    """获取文件信息"""
    try:
        stat = os.stat(filepath)
        return {
            "path": filepath,
            "size": stat.st_size,
            "mtime": stat.st_mtime,
            "mtime_str": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
        }
    except Exception as e:
        return None

def monitor_db_changes():
    """监控数据库文件变化"""
    log("=== WeChat FSMonitor 启动 ===")
    log(f"监控目录: {XWECHAT_FILES}")
    
    # 获取用户目录
    user_dirs = get_user_dirs()
    if not user_dirs:
        log("未找到用户数据目录")
        return
    
    log(f"找到 {len(user_dirs)} 个用户目录: {user_dirs}")
    
    # 初始快照
    file_states = {}
    for user_dir in user_dirs:
        db_files = get_db_files(user_dir)
        for db_file in db_files:
            info = get_file_info(db_file)
            if info:
                file_states[db_file] = info
    
    log(f"监控 {len(file_states)} 个数据库文件")
    
    # 主监控循环
    poll_interval = 1.0  # 1秒检查一次
    
    try:
        while True:
            time.sleep(poll_interval)
            
            for user_dir in user_dirs:
                db_files = get_db_files(user_dir)
                for db_file in db_files:
                    info = get_file_info(db_file)
                    if not info:
                        continue
                    
                    old_info = file_states.get(db_file)
                    
                    if old_info is None:
                        # 新文件
                        log(f"[新文件] {os.path.basename(db_file)}")
                        file_states[db_file] = info
                    elif info["mtime"] != old_info["mtime"]:
                        # 文件已修改
                        size_change = info["size"] - old_info["size"]
                        db_name = os.path.basename(db_file)
                        
                        # 检测消息相关数据库的变化
                        if "message" in db_file.lower() or "msg" in db_file.lower():
                            log(f"[消息变化] {db_name} 大小变化: {size_change:+d} 字节")
                            
                            # 检查是否可能是撤回 (通常文件大小没有明显增加)
                            if size_change <= 0:
                                log(f"  ⚠️ 可能是撤回或删除操作!")
                        else:
                            log(f"[文件变化] {db_name} 大小变化: {size_change:+d} 字节")
                        
                        file_states[db_file] = info
            
    except KeyboardInterrupt:
        log("监控已停止")

def analyze_db_structure():
    """分析数据库结构 (尝试读取未加密的元数据)"""
    log("=== 分析数据库结构 ===")
    
    user_dirs = get_user_dirs()
    for user_dir in user_dirs:
        db_files = get_db_files(user_dir)
        
        for db_file in db_files:
            try:
                # 尝试连接数据库
                conn = sqlite3.connect(db_file)
                cursor = conn.cursor()
                
                # 获取所有表
                cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
                tables = cursor.fetchall()
                
                if tables:
                    log(f"[可读] {os.path.basename(db_file)}: {[t[0] for t in tables]}")
                
                conn.close()
            except sqlite3.DatabaseError as e:
                # 加密的数据库
                error_msg = str(e)
                if "file is not a database" in error_msg or "encrypted" in error_msg.lower():
                    log(f"[加密] {os.path.basename(db_file)}")
                else:
                    log(f"[错误] {os.path.basename(db_file)}: {e}")
            except Exception as e:
                log(f"[错误] {os.path.basename(db_file)}: {e}")

def main():
    if len(sys.argv) > 1:
        if sys.argv[1] == "--analyze":
            analyze_db_structure()
        elif sys.argv[1] == "--help":
            print(__doc__)
        else:
            print(f"未知参数: {sys.argv[1]}")
            print("用法: python3 Scripts/fsmonitor.py [--analyze]")
    else:
        monitor_db_changes()

if __name__ == "__main__":
    main()
