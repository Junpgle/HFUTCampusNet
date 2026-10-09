#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
合肥工业大学校园网自服务监测 & 自动登录 & 实时网速 CLI 工具
- 校园网认证接口: http://172.18.3.3/
- 自服务数据接口: https://xywzz.hfut.edu.cn:8443/Self/dashboard
"""

import sys
import os
import re
import time
import ssl
import json
import hashlib
import argparse
import subprocess
import urllib.request
import urllib.parse
from datetime import datetime

CONFIG_PATH = os.path.expanduser("~/.hfut_campusnet.json")
PORTAL_URL = "http://172.18.3.3/"
LOGOUT_URL = "http://172.18.3.3/F.htm"
DASHBOARD_URL = "https://xywzz.hfut.edu.cn:8443/Self/dashboard"
SELF_LOGIN_URL = "https://xywzz.hfut.edu.cn:8443/Self/login/?302=LI"

def get_ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx

def load_config():
    data = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            pass
    return data

def save_config(new_data):
    data = load_config()
    data.update(new_data)
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def get_portal_credentials():
    config = load_config()
    username = config.get("username", "")
    password = config.get("password", "")

    if not username or not password:
        try:
            u_proc = subprocess.run(
                ["defaults", "read", "cn.edu.hfut.campusnet.monitor", "campus_portal_username"],
                capture_output=True, text=True
            )
            p_proc = subprocess.run(
                ["defaults", "read", "cn.edu.hfut.campusnet.monitor", "campus_portal_password"],
                capture_output=True, text=True
            )
            if u_proc.returncode == 0 and u_proc.stdout.strip():
                username = username or u_proc.stdout.strip()
            if p_proc.returncode == 0 and p_proc.stdout.strip():
                password = password or p_proc.stdout.strip()
        except Exception:
            pass
    return username, password

def get_cookie():
    if "HFUT_COOKIE" in os.environ:
        return os.environ["HFUT_COOKIE"]
    config = load_config()
    if config.get("cookie"):
        return config["cookie"]
    try:
        proc = subprocess.run(
            ["defaults", "read", "cn.edu.hfut.campusnet.monitor", "campus_session_cookie"],
            capture_output=True, text=True
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
    except Exception:
        pass
    return None

def get_net_bytes():
    try:
        out = subprocess.check_output(["netstat", "-ibn"], stderr=subprocess.DEVNULL).decode("utf-8")
        lines = out.splitlines()[1:]
        total_i = 0
        total_o = 0
        seen = set()
        for l in lines:
            parts = l.split()
            if len(parts) >= 10 and not parts[0].startswith("lo"):
                iface = parts[0]
                if iface not in seen:
                    seen.add(iface)
                    try:
                        total_i += int(parts[6])
                        total_o += int(parts[9])
                    except Exception:
                        pass
        return total_i, total_o
    except Exception:
        return 0, 0

def measure_speed(duration=1.0):
    b1_i, b1_o = get_net_bytes()
    time.sleep(duration)
    b2_i, b2_o = get_net_bytes()
    diff_i = max(0, b2_i - b1_i) / duration
    diff_o = max(0, b2_o - b1_o) / duration
    return diff_i, diff_o

def format_speed(bytes_per_sec):
    if bytes_per_sec >= 1024 * 1024 * 1024:
        return f"{bytes_per_sec / (1024*1024*1024):.2f} GB/s"
    elif bytes_per_sec >= 1024 * 1024:
        return f"{bytes_per_sec / (1024*1024):.1f} MB/s"
    elif bytes_per_sec >= 1024:
        return f"{bytes_per_sec / 1024:.0f} KB/s"
    else:
        return f"{bytes_per_sec:.0f} B/s"

def check_portal_status():
    req = urllib.request.Request(PORTAL_URL, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=4) as resp:
            html = resp.read().decode("ascii", errors="ignore")
            if "<!--Dr.COMWebLoginID_1.htm-->" in html or "DispTFM" in html:
                uid_m = re.search(r"uid='([^']*)'", html)
                flow_m = re.search(r"flow='([^']*)'", html)
                fee_m = re.search(r"fee='([^']*)'", html)
                time_m = re.search(r"time='([^']*)'", html)
                ip_m = re.search(r"v4ip='([^']*)'", html)

                uid = uid_m.group(1).strip() if uid_m else "未知"
                ip = ip_m.group(1).strip() if ip_m else "未知"
                flow_mb = float(flow_m.group(1).strip()) / 1024.0 if flow_m else 0.0
                fee_yuan = float(fee_m.group(1).strip()) / 10000.0 if fee_m else 0.0
                time_min = int(time_m.group(1).strip()) if time_m else 0

                return "online", {
                    "uid": uid,
                    "ip": ip,
                    "flow_mb": flow_mb,
                    "fee_yuan": fee_yuan,
                    "time_min": time_min
                }
            elif "<!--Dr.COMWebLoginID_0.htm-->" in html or "DDDDD" in html:
                return "offline", "校园网未认证/离线"
            return "unknown", "未知响应"
    except Exception as e:
        return "not_campus", f"未连接校园网: {str(e)}"

def login_portal(username, password):
    if not username or not password:
        return False, "学号或密码不能为空"

    tmpchar = "2" + password + "12345678"
    upass = hashlib.md5(tmpchar.encode("utf-8")).hexdigest() + "123456782"

    post_fields = {
        "DDDDD": username,
        "upass": upass,
        "R1": "0",
        "R2": "1",
        "para": "00",
        "0MKKey": "123456",
        "v6ip": ""
    }
    data = urllib.parse.urlencode(post_fields).encode("utf-8")
    headers = {
        "User-Agent": "Mozilla/5.0",
        "Content-Type": "application/x-www-form-urlencoded",
        "Referer": "http://172.18.3.3/0.htm"
    }

    req = urllib.request.Request(PORTAL_URL, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            html = resp.read().decode("ascii", errors="ignore")
            if "<!--Dr.COMWebLoginID_1.htm-->" in html or "DispTFM" in html:
                return True, "登录成功！"
            elif "msga='" in html:
                m = re.search(r"msga='([^']*)'", html)
                return False, f"认证失败: {m.group(1)}" if m else "认证失败"
            
            time.sleep(1)
            st, _ = check_portal_status()
            if st == "online":
                return True, "登录成功！"
            return False, "登录响应未确认，请重试"
    except Exception as e:
        return False, f"请求异常: {str(e)}"

def logout_portal():
    req = urllib.request.Request(LOGOUT_URL, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return True, "校园网已注销"
    except Exception as e:
        return False, f"注销异常: {str(e)}"

def parse_html_metrics(html):
    data = {
        "used_flow": "-- M",
        "avail_flow": "-- M",
        "protection": "-- 元",
        "balance": "-- 元"
    }
    targets = {
        "used_flow": ("已用流量", "M"),
        "avail_flow": ("可用流量", "M"),
        "protection": ("消费保护", "元"),
        "balance": ("账户余额", "元")
    }

    found_any = False
    for key, (label, fallback_unit) in targets.items():
        if label not in html:
            continue
        idx = html.find(label)
        start = max(0, idx - 250)
        end = min(len(html), idx + 250)
        window = html[start:end]
        clean = re.sub(r"<[^>]+>", " ", window)

        m_pre = re.findall(r"([\d\.]+)\s*([GMK]B?|M|G|元)?\s*" + re.escape(label), clean)
        if m_pre:
            num, unit = m_pre[0]
            unit = unit if unit else fallback_unit
            data[key] = f"{num} {unit}".strip()
            found_any = True
            continue

        m_post = re.findall(re.escape(label) + r"\s*[:：]?\s*([\d\.]+)\s*([GMK]B?|M|G|元)?", clean)
        if m_post:
            num, unit = m_post[0]
            unit = unit if unit else fallback_unit
            data[key] = f"{num} {unit}".strip()
            found_any = True
            continue

    return data if found_any else None

def fetch_dashboard(cookie):
    clean_cookie = cookie if "JSESSIONID=" in cookie else f"JSESSIONID={cookie}"
    headers = {
        "User-Agent": "Mozilla/5.0",
        "Referer": DASHBOARD_URL,
        "Cookie": clean_cookie
    }
    req = urllib.request.Request(DASHBOARD_URL, headers=headers)
    ctx = get_ssl_context()

    class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
        def http_error_302(self, req, fp, code, msg, headers):
            return fp

    opener = urllib.request.build_opener(NoRedirectHandler)
    try:
        with opener.open(req, context=ctx, timeout=8) as resp:
            location = resp.headers.get("Location", "")
            if "login" in location:
                return False, "自服务会话已过期"

            body = resp.read().decode("utf-8", errors="ignore")
            if "欢迎登录用户自助服务系统" in body and "已用流量" not in body:
                return False, "自服务会话已过期"

            parsed = parse_html_metrics(body)
            if parsed:
                return True, parsed
            return False, "自服务未能匹配到指标"
    except Exception as e:
        return False, f"连接自服务异常: {str(e)}"

def format_mb(flow_str):
    m = re.search(r"([\d\.]+)", flow_str)
    if not m:
        return flow_str
    try:
        val = float(m.group(1))
        if "G" in flow_str.upper():
            return f"{val:.1f} G"
        elif val >= 1024:
            return f"{val/1024.0:.1f} G"
        else:
            return f"{val:.0f} M"
    except Exception:
        return flow_str

def main():
    parser = argparse.ArgumentParser(description="HFUT 校园网自服务监测 & 自动登录 & 实时网速工具")
    parser.add_argument("--status", action="store_true", help="查看 172.18.3.3 在线状态")
    parser.add_argument("--speed", action="store_true", help="持续输出实时下载与上传速率")
    parser.add_argument("--login", action="store_true", help="执行校园网认证登录 (172.18.3.3)")
    parser.add_argument("--logout", action="store_true", help="注销校园网当前设备")
    parser.add_argument("--set-portal", nargs=2, metavar=("USER", "PASS"), help="设置校园网学号与密码")
    parser.add_argument("--set-cookie", type=str, help="设置并保存自服务 JSESSIONID Cookie")
    parser.add_argument("--swiftbar", action="store_true", help="以 SwiftBar/xbar 插件格式输出")
    parser.add_argument("--json", action="store_true", help="以 JSON 格式输出")
    parser.add_argument("--watch", type=int, default=0, help="持续循环刷新间隔秒数 (如 300)")

    args = parser.parse_args()

    if args.speed:
        print("🚀 正在监测实时网络速率 (按 Ctrl+C 停止)...")
        while True:
            down, up = measure_speed(1.0)
            print(f"\r  ↓ 下载: {format_speed(down):<10}   ↑ 上传: {format_speed(up):<10}", end="", flush=True)

    if args.set_portal:
        u, p = args.set_portal
        save_config({"username": u, "password": p})
        print(f"✓ 校园网账号已保存：{u}")
        return

    if args.set_cookie:
        save_config({"cookie": args.set_cookie.strip()})
        print(f"✓ 自服务 Cookie 已保存")
        return

    if args.logout:
        ok, msg = logout_portal()
        print(f"{'✓' if ok else '❌'} {msg}")
        return

    username, password = get_portal_credentials()

    if args.login:
        if not username or not password:
            print("❌ 未设置账号密码，请运行: python3 monitor.py --set-portal <学号> <密码>")
            sys.exit(1)
        ok, msg = login_portal(username, password)
        print(f"{'✓' if ok else '❌'} {msg}")
        return

    if args.status:
        st, info = check_portal_status()
        if st == "online":
            print("========================================")
            print("   合肥工业大学校园网在线状态 (172.18.3.3)")
            print("========================================")
            print(f"  🟢 在线状态 :  已认证在线")
            print(f"  👤 学号账号 :  {info['uid']}")
            print(f"  🌐 设备 IP  :  {info['ip']}")
            print(f"  📊 已用流量 :  {info['flow_mb']:.1f} MB")
            print(f"  💰 账户余额 :  {info['fee_yuan']:.2f} 元")
            print(f"  ⏱️ 在线时长 :  {info['time_min']} 分钟")
            print("========================================")
        else:
            print(f"🔴 校园网状态: {info}")
        return

    def do_fetch():
        p_st, p_info = check_portal_status()
        if p_st == "offline" and username and password:
            login_portal(username, password)
            time.sleep(1)
            p_st, p_info = check_portal_status()

        cookie = get_cookie()
        ok, res = (False, "未配置 Cookie") if not cookie else fetch_dashboard(cookie)

        if not ok and p_st == "online":
            res = {
                "used_flow": f"{p_info['flow_mb']:.0f} M",
                "avail_flow": "-- M",
                "protection": "-- 元",
                "balance": f"{p_info['fee_yuan']:.2f} 元"
            }
            ok = True

        down_speed, up_speed = measure_speed(0.4)

        if args.swiftbar:
            if not ok:
                print("📶 校园网 (未认证)")
                print("---")
                print("点击登录校园网 | href=http://172.18.3.3/")
                return
            avail_fmt = format_mb(res['avail_flow'])
            print(f"📶 {avail_fmt} | ↓{format_speed(down_speed)}")
            print("---")
            print(f"🚀 实时网速: ↓ {format_speed(down_speed)}   ↑ {format_speed(up_speed)} | color=teal font=Menlo")
            print("---")
            print(f"📊 已用流量: {res['used_flow']} ({format_mb(res['used_flow'])}) | font=Menlo")
            print(f"📶 可用流量: {res['avail_flow']} ({avail_fmt}) | font=Menlo")
            print(f"💰 账户余额: {res['balance']} | font=Menlo")
            print(f"🛡️ 消费保护: {res['protection']} | font=Menlo")
            print("---")
            print(f"⏱️ 更新于 {datetime.now().strftime('%H:%M:%S')} | size=11 color=gray")
            print("🔄 立即刷新 | refresh=true")
            print("🌐 打开自服务后台 | href=" + DASHBOARD_URL)
            return

        if args.json:
            out_data = res if ok else {}
            out_data["speed_download"] = format_speed(down_speed)
            out_data["speed_upload"] = format_speed(up_speed)
            print(json.dumps({"success": ok, "data": out_data, "error": None if ok else res}, ensure_ascii=False, indent=2))
            return

        if not ok:
            print(f"❌ 获取失败: {res}")
            return

        print("========================================")
        print("   合肥工业大学校园网监测 (自服务 & 网关)")
        print("========================================")
        print(f"  📶 可用流量 :  {res['avail_flow']} (约 {format_mb(res['avail_flow'])})")
        print(f"  📊 已用流量 :  {res['used_flow']} (约 {format_mb(res['used_flow'])})")
        print(f"  💰 账户余额 :  {res['balance']}")
        print(f"  🛡️ 消费保护 :  {res['protection']}")
        print(f"  🚀 实时速率 :  ↓ {format_speed(down_speed)}   ↑ {format_speed(up_speed)}")
        print(f"  ⏱️ 更新时间 :  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print("========================================")

    if args.watch > 0:
        print(f"🚀 开始持续监测 (间隔 {args.watch} 秒)...")
        while True:
            do_fetch()
            time.sleep(args.watch)
    else:
        do_fetch()

if __name__ == "__main__":
    main()
