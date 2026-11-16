#!/usr/bin/ucode
/* MMDVM Dashboard API —— uhttpd CGI 入口，URL: /api/<endpoint> */
let FS = require("fs");

const INI_DIR = "/etc/mmdvm/";
const STATE   = "/etc/mmdvm/dashboard.json";
const QSO_CACHE = "/tmp/dashboard_qso.cache";
const LH_CACHE  = "/tmp/dashboard_lh.cache";
/* 最近通联持久化（overlay 分区，重启不丢）：按 DMR ID 聚合 */
const LH_STORE    = "/root/dashboard-lh.json";
const LH_MAX_IDS  = 200;   /* 最多保留的 ID 数，超出淘汰最久未通联的 */
const LH_MAX_HIST = 30;    /* 每个 ID 保留的历史条数 */
const STATUS_CACHE = "/tmp/dashboard_status.cache";
const LIVE_CACHE   = "/tmp/dashboard_live.cache";
const PING_CACHE   = "/tmp/dashboard_ping.json";
const CPU_CACHE    = "/tmp/dashboard_cpu.json";
const CONN_CACHE   = "/tmp/dashboard_conn.cache";
const GPS_CACHE    = "/tmp/dashboard_gps.json";
const GEO_CACHE    = "/tmp/dashboard_geo.json";
/* 逆地理结果缓存：成功的存 7 天，失败的只存 5 分钟 */
const GEO_TTL      = 604800;
/* 短缓存有效期（秒）：仅用于 status / live 这类高频接口，需小于前端轮询周期 */
const SHORT_TTL = 1;

/* ---------- 基础工具 ---------- */
function sh(cmd) {
	let p = FS.popen(cmd);
	if (!p) return "";
	let o = p.read("all");
	p.close();
	return o ?? "";
}
function rnd(x) { return int(x + 0.5); }
function words(s) {
	let r = [];
	for (let w in split(trim(s), " ")) if (length(w)) push(r, w);
	return r;
}
function out(obj) {
	print("Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n");
	print(sprintf("%J", obj));
}
function fail(msg) { out({ ok: false, error: msg }); }
function ep() {
	let s = getenv("SCRIPT_NAME") ?? "";
	let a = split(s, "/");
	return a[length(a) - 1];
}
function pathinfo() { return trim(getenv("PATH_INFO") ?? ""); }
function qs() {
	let o = {};
	let q = getenv("QUERY_STRING") ?? "";
	for (let kv in split(q, "&")) {
		if (!length(kv)) continue;
		let i = index(kv, "=");
		if (i < 0) { o[kv] = ""; continue; }
		o[substr(kv, 0, i)] = substr(kv, i + 1);
	}
	return o;
}
function body() {
	let b = FS.stdin.read("all") ?? "";
	if (!length(trim(b))) return null;
	/* 请求体不是合法 JSON 时返回 null，避免 ucode 抛错导致 502 */
	let v = null;
	try { v = json(b); } catch (e) { v = null; }
	return (type(v) == "object") ? v : null;
}
function ini(file) {
	let data = FS.readfile(file);
	if (data == null) return {};
	let res = {}, cur = null;
	for (let line in split(data, "\n")) {
		let l = trim(line);
		if (!length(l) || substr(l, 0, 1) == ";" || substr(l, 0, 1) == "#") continue;
		if (substr(l, 0, 1) == "[" && substr(l, length(l) - 1) == "]") {
			cur = substr(l, 1, length(l) - 2);
			res[cur] = {};
		} else if (cur != null) {
			let i = index(l, "=");
			if (i > 0) res[cur][trim(substr(l, 0, i))] = trim(substr(l, i + 1));
		}
	}
	return res;
}
function state() {
	let data = FS.readfile(STATE);
	if (data == null) return {};
	let v = json(data);
	return (type(v) == "object") ? v : {};
}
function saveState(o) { FS.writefile(STATE, sprintf("%J", o) + "\n"); }

/* 文件签名：路径+大小+修改时间，用于判断日志/数据库是否变化 */
function fileSig(file) {
	if (!length(file)) return "";
	let s = FS.stat(file);
	return (s == null) ? (file + "|0|0") : (file + "|" + s.size + "|" + s.mtime);
}
/* 先写临时文件再改名，避免并发请求读到半截 JSON */
function writeCache(path, obj) {
	let tmp = path + ".tmp";
	FS.writefile(tmp, sprintf("%J", obj));
	FS.rename(tmp, path);
}
/* 短缓存：来源日志签名变化立即失效（优先判断，保证新通话不被 TTL 拖住），
   日志未变化时才按 ttl 复用，命中时不再 fork / 解析日志 */
function shortGet(path, ttl, file) {
	let d = FS.readfile(path);
	if (d == null || substr(trim(d), 0, 1) != "{") return null;
	let v = json(d);
	if (type(v) != "object" || v == null || v.body == null) return null;
	if (length(file) && (v.file != file || v.sig != fileSig(file))) return null;
	if (time() - (v.t ?? 0) > ttl) return null;
	return v.body;
}
function shortPut(path, body, file) {
	let tmp = path + ".tmp";
	FS.writefile(tmp, sprintf("%J", {
		t: time(),
		file: file ?? "",
		sig: length(file) ? fileSig(file) : "",
		body: body
	}));
	FS.rename(tmp, path);
}
/* 呼号/地址查询结果短缓存：同一批呼号的 grep / awk 结果 60 秒内不再重复 fork。
   这类数据一天内基本不变，实时性只影响新出现的呼号，60 秒足够 */
const MEMO = "/tmp/dashboard_memo.json";
function keyOf(prefix, a, b) {
	let s = prefix;
	if (a != null) for (let x in a) s += x + ",";
	if (b != null) { s += "|"; for (let x in b) s += x + ","; }
	return s;
}
function memoGet(k, ttl) {
	let d = FS.readfile(MEMO);
	if (d == null) return null;
	let m = json(d);
	if (type(m) != "object" || m == null) return null;
	let e = m[k];
	if (e == null || type(e) != "object") return null;
	if (time() - (e.t ?? 0) > ttl) return null;
	return e.v;
}
function memoPut(k, v) {
	let d = FS.readfile(MEMO);
	let m = (d != null) ? json(d) : null;
	if (type(m) != "object" || m == null) m = {};
	let now = time(), out = {}, n = 0;
	for (let x in m) {
		let e = m[x];
		if (type(e) == "object" && e != null && now - (e.t ?? 0) <= 300 && n < 40) { out[x] = e; n++; }
	}
	out[k] = { t: now, v: v };
	writeCache(MEMO, out);
}
function hostname() {
	let h = trim(sh("uci get system.@system[0].hostname 2>/dev/null"));
	if (!length(h)) h = trim(FS.readfile("/proc/sys/kernel/hostname") ?? "");
	return h;
}

/* ---------- 服务定义（与设备实际安装一致） ---------- */
const SVCS = [
	{ key: "mmdvmhost",   name: "MMDVMHost",   bin: "/usr/bin/MMDVMHost",   proc: "MMDVMHost",   ini: "MMDVM.ini" },
	{ key: "dmrgateway",  name: "DMRGateway",  bin: "/usr/bin/DMRGateway",  proc: "DMRGateway",  ini: "DMRGateway.ini" }
];
function svcFind(key) {
	for (let s in SVCS) if (s.key == key) return s;
	return null;
}
function svcInfo(s) {
	return {
		key: s.key, name: s.name, bin: s.bin,
		config: INI_DIR + s.ini,
		running: length(trim(sh("pidof " + s.proc + " 2>/dev/null"))) > 0,
		enabled: length(trim(sh("ls /etc/rc.d/S*" + s.key + " 2>/dev/null"))) > 0
	};
}
const LOGPATH_CACHE = "/tmp/dashboard_logpath.json";
/* 日志路径：ls -t 每次请求都要 fork，2 秒内复用同一结果。
   日志按天滚动，最多让新文件晚 2 秒被发现，不影响实时显示 */
function logFileFor(prefix) {
	let now = time(), c = null;
	try { c = json(FS.readfile(LOGPATH_CACHE) ?? ""); } catch (e) { c = null; }
	if (type(c) != "object" || c == null) c = {};
	let e = c[prefix];
	if (type(e) == "object" && e != null && now - (e.t ?? 0) <= 2 && length(e.f ?? "") && FS.stat(e.f) != null)
		return e.f;
	let f = trim(sh("ls -t /var/log/mmdvm/" + prefix + "-*.log 2>/dev/null | head -1"));
	c[prefix] = { t: now, f: f };
	try { FS.writefile(LOGPATH_CACHE, sprintf("%J", c)); } catch (e2) {}
	return f;
}
/* 直连模式下 MMDVMHost 与 master 的连接状态。
   日志可能上百 KB/小时，登录事件常在文件前部，按增量读取：
   只解析上次记录偏移之后新增的内容，避免每次重复扫描整份日志 */
/* 屏幕端口所在的 ini 段随屏幕类型变化：[Nextion] / [OLED] / [TFT Serial]；
   HD44780 用 Pins 定义、None 不需要端口，均返回 null */
function dispSectionFor(t) {
	let s = trim(t ?? "");
	if (s == "Nextion") return "Nextion";
	if (s == "OLED" || s == "OLED Type3" || s == "OLED Type6") return "OLED";
	if (s == "TFT Serial") return "TFT Serial";
	return null;
}
function directConnected(file) {
	if (!length(file)) return false;
	let st = FS.stat(file);
	if (st == null) return false;
	let sig = file + "|" + st.size + "|" + st.mtime;
	let c = null;
	try { c = json(FS.readfile(CONN_CACHE) ?? ""); } catch (e) { c = null; }
	let same = (c != null && c.file == file);
	if (same && c.sig == sig) return !!c.connected;
	let conn = same ? !!c.connected : false;
	let from = 0;
	if (same && type(c.off) == "int" && c.off > 0 && c.off <= st.size) from = c.off;
	/* 回退 200 字节，避免把上次末尾的半行当成新行解析 */
	if (from > 200) from -= 200;
	let chunk = (from > 0) ? sh("tail -c +" + (from + 1) + " " + file) : (FS.readfile(file) ?? "");
	for (let l in split(chunk, "\n")) {
		if (index(l, "Logged into the master successfully") >= 0) conn = true;
		else if (index(l, "Connection to the master has timed out") >= 0) conn = false;
		else if (index(l, "Closing DMR Network") >= 0) conn = false;
		else if (index(l, "Opening DMR Network") >= 0) conn = false;
	}
	let off = from + length(chunk);
	try { FS.writefile(CONN_CACHE, sprintf("%J", { file: file, sig: sig, off: off, connected: conn })); } catch (e) {}
	return conn;
}

/* ---------- 日志解析 ---------- */
function between(s, a, b) {
	let i = index(s, a);
	if (i < 0) return null;
	s = substr(s, i + length(a));
	if (b == null) return s;
	let j = index(s, b);
	return (j < 0) ? null : substr(s, 0, j);
}
function slotOf(line) {
	let v = between(line, "Slot ", ",");
	return (v == null) ? null : trim(v);
}
function tsOf(line) {
	let i = index(line, "20");
	if (i < 0) return "";
	let t = substr(line, i, 19);
	return (length(t) == 19 && substr(t, 4, 1) == "-") ? t : "";
}
function hhmmss(t) { return length(t) >= 19 ? substr(t, 11, 8) : ""; }
/* 日志时间为 UTC，busybox date 不支持 -d，这里直接按 UTC 计算 epoch */
function epochOf(t) {
	if (length(t) < 19) return 0;
	let y = +substr(t, 0, 4), mo = +substr(t, 5, 2), d = +substr(t, 8, 2);
	let h = +substr(t, 11, 2), mi = +substr(t, 14, 2), se = +substr(t, 17, 2);
	if (!y || !mo || !d) return 0;
	let yy = (mo <= 2) ? y - 1 : y;
	let era = int(yy / 400);
	let yoe = yy - era * 400;
	let mp = (mo > 2) ? mo - 3 : mo + 9;
	let doy = int((153 * mp + 2) / 5) + d - 1;
	let doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy;
	return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + se;
}
/* ---------- 内嵌 GPS / 逆地理 ---------- */
/* MMDVMHost 会把对端语音头里的内嵌 GPS 打成两行：
   “DMR Slot N, Embedded GPS Info” 紧跟 “GPS position [lat, lon]”
   按槽位记录最后一次坐标，增量读取日志避免整份重扫 */
function gpsBySlot(file) {
	if (!length(file)) return {};
	let st = FS.stat(file);
	if (st == null) return {};
	let sig = file + "|" + st.size + "|" + st.mtime;
	let c = null;
	try { c = json(FS.readfile(GPS_CACHE) ?? ""); } catch (e) { c = null; }
	let same = (c != null && c.file == file && type(c.slots) == "object");
	if (same && c.sig == sig) return c.slots;
	let slots = same ? c.slots : {};
	let lastSlot = same ? (c.lastSlot ?? null) : null;
	let from = 0;
	if (same && type(c.off) == "int" && c.off > 0 && c.off <= st.size) from = c.off;
	if (from > 300) from -= 300;
	let chunk = (from > 0) ? sh("tail -c +" + (from + 1) + " " + file) : (FS.readfile(file) ?? "");
	for (let l in split(chunk, "\n")) {
		if (index(l, "Embedded GPS Info") >= 0) {
			let sl = slotOf(l);
			if (sl != null) lastSlot = sl;
			continue;
		}
		let gi = index(l, "GPS position [");
		if (gi < 0 || lastSlot == null) continue;
		let rest = substr(l, gi + 14);
		let ci = index(rest, ",");
		if (ci <= 0) continue;
		let la = trim(substr(rest, 0, ci));
		let tail = substr(rest, ci + 1);
		let ei = index(tail, "]");
		let lo = (ei > 0) ? trim(substr(tail, 0, ei)) : "";
		if (!length(la) || !length(lo)) continue;
		slots[lastSlot] = { lat: +la, lon: +lo, ts: epochOf(tsOf(l)) };
	}
	try { FS.writefile(GPS_CACHE, sprintf("%J", { file: file, sig: sig, off: from + length(chunk), lastSlot: lastSlot, slots: slots })); } catch (e) {}
	return slots;
}
/* 逆地理缓存键：0.01° 网格 */
function geoKey(lat, lon) { return sprintf("%.2f,%.2f", +lat, +lon); }
/* 只读缓存，不发网络请求 —— 实时接口靠它保持毫秒级响应 */
function addrCached(lat, lon) {
	let key = geoKey(lat, lon), c = {};
	try { c = json(FS.readfile(GEO_CACHE) ?? "") ?? {}; } catch (e) { c = {}; }
	if (type(c) != "object" || c == null) return "";
	let e = c[key];
	if (e == null || !length(e.addr ?? "")) return "";
	if (time() - (e.t ?? 0) >= GEO_TTL) return "";
	return e.addr;
}
/* 后台进程查地址，不阻塞实时接口；同一网格 60 秒内只触发一次 */
function addrPrefetch(lat, lon) {
	let mk = "/tmp/dashboard_geo_" + replace(geoKey(lat, lon), ",", "_");
	let st = FS.stat(mk);
	if (st != null && time() - (st.mtime ?? 0) < 60) return;
	try { FS.writefile(mk, ""); } catch (e) {}
	sh("(SCRIPT_NAME=/api/geo QUERY_STRING='lat=" + (+lat) + "&lon=" + (+lon) + "' ucode /www-dash/api/api.uc >/dev/null 2>&1) &");
}
/* 逆地理：高德网页版接口无需 key，返回省/市/区县；按 0.01°（约 1km）网格缓存 */
function addrOf(lat, lon) {
	let key = sprintf("%.2f,%.2f", lat, lon);
	let now = time(), c = {};
	try { c = json(FS.readfile(GEO_CACHE) ?? "") ?? {}; } catch (e) { c = {}; }
	if (type(c) != "object") c = {};
	let e = c[key];
	if (e != null && now - (e.t ?? 0) < ((length(e.addr ?? "") ? GEO_TTL : 300))) return e.addr ?? "";
	let u = "https://ditu.amap.com/service/regeo?longitude=" + lon + "&latitude=" + lat + "&lang=zh_cn";
	let o = sh("uclient-fetch -q -O - --timeout=4 '" + u + "' 2>/dev/null");
	let addr = "";
	try {
		let j = json(o);
		let d = (type(j) == "object") ? (j.data ?? null) : null;
		if (type(d) == "object" && d != null) {
			let pv = trim(d.province ?? ""), ct = trim(d.city ?? ""), dt = trim(d.district ?? "");
			if (pv != "0") addr = pv;
			if (length(ct) && ct != "0" && ct != pv) addr += ct;
			if (length(dt) && dt != "0" && dt != ct) addr += dt;
		}
	} catch (ex) {}
	c[key] = { t: now, addr: addr };
	try { FS.writefile(GEO_CACHE, sprintf("%J", c)); } catch (ex2) {}
	return addr;
}
/* 两点距离（km）：球面半正矢公式，sin/cos/asin 用泰勒展开、开方用牛顿迭代，
   避免依赖本机 ucode 构建里缺失的数学函数 */
function cosDeg(d) {
	let r = d * 0.0174532925199433, r2 = r * r;
	return 1 - r2 / 2 + r2 * r2 / 24 - r2 * r2 * r2 / 720;
}
function sinDeg(d) {
	let r = d * 0.0174532925199433, r2 = r * r, r3 = r2 * r;
	return r - r3 / 6 + r3 * r2 / 120 - r3 * r2 * r2 / 5040;
}
function asinX(x) {
	let x3 = x * x * x;
	return x + x3 / 6 + 3 * x3 * x * x / 40;
}
function fsqrt(x) {
	if (x <= 0) return 0;
	let g = x;
	for (let i = 0; i < 24; i++) g = (g + x / g) / 2;
	return g;
}
function distKm(la1, lo1, la2, lo2) {
	let a = sinDeg((la2 - la1) / 2), b = sinDeg((lo2 - lo1) / 2);
	let t = a * a + cosDeg(la1) * cosDeg(la2) * b * b;
	if (t < 0) t = 0;
	if (t > 1) t = 1;
	return 2 * 6371.0 * asinX(fsqrt(t));
}

function parseQso(logfile) {
	let file = logfile ?? logFileFor("MMDVM");
	let recs = [], pend = {}, rt = {};
	/* 逐突发误码累计器：errs/total 为比特级计数，frames 为突发数。
	   跨轮询累计，前端用相邻两次的快照做差分，既不漏帧也不重复计数。
	   jumps/jsum 为跳变统计：相邻突发错误比特数变化 ≥3 记一次，jsum 为跳变量总和 */
	let cal = { errs: 0, total: 0, frames: 0, jumps: 0, jsum: 0, ts: "" };
	/* 每个时隙上一突发的错误比特数；跨发射段重置，避免首尾相接被算成跳变 */
	let calp = {};
	/* 每个时隙最后一次在日志里出现活动的时间：网络下行通话没有音频统计行，
	   用它判断呼叫是否仍在进行，避免只按音频统计超时导致漏显 */
	let seen = {};
	/* “Embedded GPS Info” 行带时隙，紧随的 “GPS position” 行不带，用它补上 */
	let gpsSlot = null;
	if (!length(file)) return { recs: recs, pend: pend, rt: rt, cal: cal };
	let st = FS.stat(file);
	if (st == null) return { recs: recs, pend: pend, rt: rt, cal: cal };
	let sig = file + "|" + st.size + "|" + st.mtime;
	let c = null;
	try {
		let d = FS.readfile(QSO_CACHE);
		if (d != null && substr(trim(d), 0, 1) == "{") c = json(d);
	} catch (e) { c = null; }
	/* 日志未变化时直接复用上次解析结果 */
	if (type(c) == "object" && c != null && c.sig == sig && type(c.recs) == "array" && type(c.pend) == "object")
		return { recs: c.recs, pend: c.pend, rt: (type(c.rt) == "object") ? c.rt : {},
			cal: (type(c.cal) == "object" && c.cal != null) ? c.cal : cal,
			seen: (type(c.seen) == "object" && c.seen != null) ? c.seen : {} };
	/* 增量解析：只读上次偏移之后的新内容。
	   整份日志每小时上百 KB，发射时每 60ms 一行音频统计，若固定只读末尾窗口，
	   长通话的 voice header 会被挤出窗口，导致「正在发射」被误判为空闲 */
	let from = 0;
	if (type(c) == "object" && c != null && c.file == file && type(c.off) == "int") {
		if (c.off > 0 && c.off <= st.size) {
			from = c.off;
			recs = (type(c.recs) == "array") ? c.recs : [];
			pend = (type(c.pend) == "object" && c.pend != null) ? c.pend : {};
			rt = (type(c.rt) == "object" && c.rt != null) ? c.rt : {};
			if (type(c.cal) == "object" && c.cal != null) {
				cal = c.cal;
				if (cal.frames == null) cal.frames = 0;
				if (cal.jumps == null) cal.jumps = 0;
				if (cal.jsum == null) cal.jsum = 0;
			}
			calp = (type(c.calp) == "object" && c.calp != null) ? c.calp : {};
			seen = (type(c.seen) == "object" && c.seen != null) ? c.seen : {};
			gpsSlot = (type(c.gpsSlot) == "int") ? c.gpsSlot : null;
		}
	}
	let data = "", base = from;
	if (from > 0) {
		data = sh("tail -c +" + (from + 1) + " " + file);
	} else {
		data = FS.readfile(file) ?? "";
		/* 首次或换文件：只解析末尾一段，base 记录被丢弃的字节数，保证偏移可续 */
		if (length(data) > 400000) {
			base = length(data) - 400000;
			data = substr(data, length(data) - 400000);
		}
	}
	/* 只处理到最后一个完整行，剩下的半行留到下次 */
	let nl = rindex(data, "\n");
	let consumed = 0;
	if (nl >= 0) {
		consumed = nl + 1;
		data = substr(data, 0, consumed);
	} else {
		data = "";
	}
	if (!length(data) && from <= 0) {
		return { recs: recs, pend: pend, rt: rt, cal: cal };
	}
	for (let line in split(data, "\n")) {
		let slot = slotOf(line);
		/* 记录该时隙最后一次活动时间（voice header、talker alias、音频统计、数据突发都算） */
		if (slot != null) seen[slot] = tsOf(line);
		/* 内嵌 GPS：先出现带时隙的“Embedded GPS Info”，紧跟一行不带时隙的“GPS position [lat, lon]” */
		if (index(line, "Embedded GPS Info") >= 0) { gpsSlot = slot; continue; }
		let gi = index(line, "GPS position [");
		if (gi >= 0) {
			let sl = (gpsSlot != null) ? gpsSlot : slot;
			let rest = substr(line, gi + 14);
			let ci = index(rest, ",");
			if (ci > 0 && sl != null) {
				let la = trim(substr(rest, 0, ci));
				let tail = substr(rest, ci + 1);
				let ei = index(tail, "]");
				let lo = (ei > 0) ? trim(substr(tail, 0, ei)) : "";
				if (length(la) && length(lo) && sl != null) {
					let g = { lat: +la, lon: +lo, ts: tsOf(line) };
					let gts = epochOf(g.ts);
					/* GPS 行常在通话结束后才落盘：先挂到当前呼叫，否则回填刚结束的那条记录，
					   避免被算到下一个呼叫上 */
					if (pend[sl] != null && (!gts || gts >= epochOf(pend[sl].ts) - 2)) {
						pend[sl].gps = g;
					} else {
						for (let i = length(recs) - 1; i >= 0; i--) {
							let q = recs[i];
							if (q.slot != sl) continue;
							let qs = epochOf(q.ts);
							if (!gts || !qs || (gts >= qs - 2 && gts <= qs + (+q.dur) + 5)) q.gps = g;
							break;
						}
					}
				}
			}
			gpsSlot = null;
			continue;
		}
		if (slot == null) continue;
		/* 发射中每个超帧的实时误码率：DMR Slot 1, audio sequence no. 2, errs: 22/141 (15.6%)
		   每行是单突发（60ms）统计：errs 为本突发修复的错误比特数，total 恒为 141 比特 */
		if (index(line, "audio sequence no.") >= 0) {
			let pct = between(line, "(", "%)");
			let es = between(line, "errs: ", "/");
			let tt = between(line, "/", " (");
			let sq = between(line, "audio sequence no. ", ",");
			let ts = tsOf(line);
			if (pct != null) rt[slot] = {
				pct: +pct,
				errs: (es != null) ? +es : 0,
				total: (tt != null) ? +tt : 141,
				seq: (sq != null) ? +sq : -1,
				ts: ts
			};
			if (es != null && tt != null) {
				let e = +es;
				let pv = calp[slot];
				if (pv != null) {
					let d = e - pv;
					if (d < 0) d = -d;
					if (d >= 3) { cal.jumps += 1; cal.jsum += d; }
				}
				calp[slot] = e;
				cal.errs += e;
				cal.total += +tt;
				cal.frames += 1;
				cal.ts = ts;
			}
			continue;
		}
		if (index(line, "voice header from ") >= 0) {
			let rest = substr(line, index(line, "voice header from ") + 18);
			let call = trim(split(trim(rest), " ")[0]);
			let target = "";
			let ti = index(rest, " to ");
			if (ti >= 0) target = trim(substr(rest, ti + 4));
			pend[slot] = {
				callsign: call, target: target,
				isId: (match(call, /^[0-9]+$/) != null),
				dir: (index(line, "received RF") >= 0) ? "TX" : "RX",
				ts: tsOf(line)
			};
			delete calp[slot];   /* 新发射段：跳变从本段第一个突发重新起算 */
			continue;
		}
		/* DMR 数据突发（APRS / 短信等）：没有 voice header，单独识别，否则通联记录里看不到 */
		if (index(line, "data header from ") >= 0) {
			let rest = substr(line, index(line, "data header from ") + 17);
			let call = trim(split(trim(rest), " ")[0]);
			let target = "";
			let ti = index(rest, " to ");
			if (ti >= 0) target = trim(substr(rest, ti + 4));
			if (index(target, ",") >= 0) target = trim(substr(target, 0, index(target, ",")));
			pend[slot] = {
				callsign: call, target: target, data: true,
				isId: (match(call, /^[0-9]+$/) != null),
				dir: (index(line, "received RF") >= 0) ? "TX" : "RX",
				ts: tsOf(line)
			};
			delete calp[slot];
			continue;
		}
		if (index(line, "ended RF data transmission") >= 0 || index(line, "ended network data transmission") >= 0) {
			let p = pend[slot];
			if (p == null || !p.data) continue;
			let ts = epochOf(p.ts), ets = epochOf(tsOf(line));
			let dur = (ts && ets && ets >= ts) ? ets - ts : 0;
			push(recs, {
				callsign: p.callsign, isId: p.isId, target: p.target, dir: p.dir,
				slot: slot, ts: p.ts, dur: dur, ber: 0, rssi: null,
				gps: (p.gps != null) ? p.gps : null, data: true
			});
			delete pend[slot];
			delete calp[slot];
			continue;
		}
		if (index(line, "end of voice transmission") >= 0) {
			let p = pend[slot];
			if (p == null || p.data) continue;
			/* 结束行形如：... to TG 91, 1.3 seconds, 4% packet loss, BER: 0.0% */
			let dur = 0;
			let si = index(line, " seconds");
			if (si >= 0) {
				let head = substr(line, 0, si);
				let ci = rindex(head, ", ");
				if (ci >= 0) dur = +substr(head, ci + 2) || 0;
			}
			let ber = between(line, "BER: ", "%");
			let rssi = between(line, "RSSI: ", "/");
			push(recs, {
				callsign: p.callsign, isId: p.isId, target: p.target, dir: p.dir,
				slot: slot, ts: p.ts,
				dur: dur,
				ber: (ber != null) ? +ber : 0,
				rssi: (rssi != null) ? +rssi : null,
				gps: (p.gps != null) ? p.gps : null
			});
			delete pend[slot];
			delete calp[slot];
		} else if (index(line, "network watchdog has expired") >= 0) {
			/* 网络侧通话可能没有 end of voice transmission，靠看门狗超时收尾。
			   只清理网络收到的通话：本机 RF 发射期间若混入别的时隙残留看门狗行，会把正在发射的状态误清掉。
			   超时行同样带时长与 BER，按结束行处理，避免这类通话从通联记录里丢失 */
			let p = pend[slot];
			if (p != null && p.dir == "RX" && !p.data) {
				let dur = 0;
				let si = index(line, " seconds");
				if (si >= 0) {
					let head = substr(line, 0, si);
					let ci = rindex(head, ", ");
					if (ci >= 0) dur = +substr(head, ci + 2) || 0;
				}
				let ber = between(line, "BER: ", "%");
				push(recs, {
					callsign: p.callsign, isId: p.isId, target: p.target, dir: p.dir,
					slot: slot, ts: p.ts, dur: dur,
					ber: (ber != null) ? +ber : 0, rssi: null,
					gps: (p.gps != null) ? p.gps : null
				});
				delete pend[slot];
				delete calp[slot];
			}
		}
	}
	/* 历史记录只保留最近 300 条，防止缓存无限增长 */
	if (length(recs) > 300) {
		let cut = [];
		for (let i = length(recs) - 300; i < length(recs); i++) push(cut, recs[i]);
		recs = cut;
	}
	if (length(sig)) writeCache(QSO_CACHE, { sig: sig, file: file, off: base + consumed, recs: recs, pend: pend, rt: rt, seen: seen, cal: cal, calp: calp, gpsSlot: gpsSlot });
	return { recs: recs, pend: pend, rt: rt, seen: seen, cal: cal };
}

/* ---------- 呼号 <-> DMR ID ---------- */
function idFor(calls) {
	let res = {};
	if (!length(calls)) return res;
	let mkey = keyOf("id:", calls, null);
	let hit = memoGet(mkey, 60);
	if (hit != null) return hit;
	let pat = "/tmp/dashboard_calls";
	let s = "";
	for (let c in calls) s += c + "\n";
	FS.writefile(pat, s);
	let cmd = "grep -F -f " + pat + " " + INI_DIR + "DMRIds.dat 2>/dev/null";
	/* DMRIds.dat 为制表符分隔，个别版本为空格分隔，两种都兼容 */
	for (let l in split(sh(cmd), "\n")) {
		let p = split(trim(l), "\t");
		if (length(p) < 2) p = split(trim(l), " ");
		if (length(p) >= 2) res[p[1]] = p[0];
	}
	memoPut(mkey, res);
	return res;
}
/* 本地 DMRIds.dat 太旧时，用缓存 + RadioID API 异步补全呼号 */
const ID_CACHE = "/etc/mmdvm/dashboard_ids.cache";
function resolveCalls(idlist) {
	let res = {};
	if (!length(idlist)) return res;
	let cache = {};
	let data = FS.readfile(ID_CACHE);
	if (data != null) {
		for (let line in split(trim(data), "\n")) {
			let p = split(line, "\t");
			if (length(p) >= 2) cache[trim(p[0])] = trim(p[1]);
		}
	}
	let miss = [];
	for (let id in idlist) {
		let c = cache[id];
		if (c != null) {
			if (c != "-" && length(c)) res[id] = c;
		} else push(miss, id);
	}
	if (length(miss)) {
		let cmd = "mmdvm-idlookup";
		let n = 0;
		for (let id in miss) {
			if (n >= 4) break;
			cmd += " " + id;
			n++;
		}
		sh("(" + cmd + ") >/dev/null 2>&1 &");
	}
	return res;
}

/* ---------- 中国呼号地址（radiowo 呼号库，86 开头 ID 使用） ---------- */
const RW_CSV = "/etc/mmdvm/radiowo_user.csv";
const RW_TS = "/etc/mmdvm/radiowo_user.ts";
const RW_TTL = 86400;
function radiowoSync() {
	let mt = int(trim(FS.readfile(RW_TS) ?? ""));
	let now = time();
	if (mt > 0 && now - mt < RW_TTL) return;
	sh("(mmdvm-radiowo-sync) >/dev/null 2>&1 &");
}

/* ---------- 中国呼号地址（BG4ESI 中文通讯录，46 开头 ID 使用） ---------- */
const BG_CSV = "/etc/mmdvm/bg4esi.csv";
const BG_TS = "/etc/mmdvm/bg4esi.ts";
const BG_TTL = 86400;
function bgSync() {
	let mt = int(trim(FS.readfile(BG_TS) ?? ""));
	let now = time();
	if (mt > 0 && now - mt < BG_TTL) return;
	sh("(mmdvm-bg4esi-sync) >/dev/null 2>&1 &");
}
function fmtAddr(state, city, remark) {
	let a = trim(state ?? ""), b = trim(city ?? ""), c = trim(remark ?? "");
	let s = a;
	if (length(b) && b != "市辖区" && b != "县" && b != a) s += (length(s) ? " " : "") + b;
	if (length(c) && c != a && c != b) s += (length(s) ? " " : "") + c;
	return s;
}
/* 一次扫描指定 CSV 库，同时得到 ID→呼号、ID→地址、呼号→地址
   stateCol/cityCol/remarkCol 为 1-based 列索引，不同数据源字段位置不同 */
function csvLookup(csvPath, idlist, clist, stateCol, cityCol, remarkCol) {
	let out = { call: {}, addrId: {}, addrCall: {}, call2id: {} };
	if (!length(idlist) && !length(clist)) return out;
	if (!length(trim(FS.readfile(csvPath) ?? ""))) return out;
	let ckey = keyOf("cv:" + csvPath + ":", idlist, clist);
	let chit = memoGet(ckey, 60);
	if (chit != null) return chit;
	let ip = "/tmp/dashboard_csvids", cp = "/tmp/dashboard_csvcalls";
	let files = "";
	if (length(idlist)) {
		let s = "";
		for (let c in idlist) s += c + "\n";
		FS.writefile(ip, s);
		files += ip + " ";
	}
	if (length(clist)) {
		let s = "";
		for (let c in clist) s += c + "\n";
		FS.writefile(cp, s);
		files += cp + " ";
	}
	let cmd = "awk -F, -v ip=" + ip + " -v cp=" + cp +
	          " -v sc=" + stateCol + " -v cc=" + cityCol + " -v rc=" + remarkCol + " " +
	          "'FILENAME==ip{ids[$0]=1;next} FILENAME==cp{calls[$0]=1;next} " +
	          "{ rm=(rc>0)?$rc:\"\"; " +
	          "  if (($1 in ids) && !($1 in seen)) { seen[$1]=1; printf \"C\\t%s\\t%s\\n\",$1,$2; printf \"D\\t%s\\t%s\\n\",$2,$1; printf \"A\\t%s\\t%s\\t%s\\t%s\\n\",$1,$sc,$cc,rm } " +
	          "  if (($2 in calls) && !($2 in bseen)) { bseen[$2]=1; printf \"D\\t%s\\t%s\\n\",$2,$1; printf \"B\\t%s\\t%s\\t%s\\t%s\\n\",$2,$sc,$cc,rm } }' " +
	          files + csvPath + " 2>/dev/null";
	for (let l in split(sh(cmd), "\n")) {
		let p = split(l, "\t");
		for (let i = 0; i < length(p); i++) p[i] = trim(p[i]);
		if (p[0] == "C" && length(p) >= 3) out.call[p[1]] = p[2];
		else if (p[0] == "D" && length(p) >= 3) out.call2id[p[1]] = p[2];
		else if (p[0] == "A" && length(p) >= 5) out.addrId[p[1]] = fmtAddr(p[2], p[3], p[4]);
		else if (p[0] == "B" && length(p) >= 5) out.addrCall[p[1]] = fmtAddr(p[2], p[3], p[4]);
	}
	memoPut(ckey, out);
	return out;
}
/* radiowo 格式: ID,CALLSIGN,NAME,CITY,STATE,COUNTRY,REMARKS → STATE=5,CITY=4,REMARKS=7 */
function rwLookup(idlist, clist) { return csvLookup(RW_CSV, idlist, clist, 5, 4, 7); }
/* BG4ESI(stripped.csv) 格式: ID,CALLSIGN,FIRST_NAME,LAST_NAME,CITY,STATE,COUNTRY → STATE=6,CITY=5,无REMARKS */
function bgLookup(idlist, clist) { return csvLookup(BG_CSV, idlist, clist, 6, 5, 0); }

/* 46/86 开头的中国 DMR ID：46 用 BG4ESI，86 用 radiowo */
function isCnId(id) {
	let p = substr(id, 0, 2);
	return (p == "46" || p == "86");
}
function is46Id(id) { return substr(id, 0, 2) == "46"; }
function is86Id(id) { return substr(id, 0, 2) == "86"; }

/* ---------- 端点实现 ---------- */
/* 自动探测：I2C 总线（/dev/i2c-N）与串口（/dev/ttyUSB* 等） */
function scanI2cBuses() {
	let res = [];
	let paths = split(trim(sh("ls /dev/i2c-* 2>/dev/null")), "\n");
	for (let i = 0; i < length(paths); i++) {
		let n = replace(trim(paths[i]), /^.*i2c-/, "");
		if (match(n, /^[0-9]+$/)) push(res, +n);
	}
	sort(res, (a, b) => a - b);
	return res;
}
function scanSerialPorts() {
	let res = [];
	let paths = split(trim(sh("ls /dev/ttyUSB* /dev/ttyACM* /dev/ttyAMA* /dev/ttyHS* 2>/dev/null")), "\n");
	for (let i = 0; i < length(paths); i++) {
		let p = trim(paths[i]);
		if (length(p) && match(p, /^\/dev\/tty[A-Za-z]+[0-9]+$/)) push(res, p);
	}
	sort(res);
	return res;
}
function cmdStatus() {
	let lf = logFileFor("MMDVM");
	/* ?ping=1：页面手动刷新时强制做一次 ping 测试，并跳过短缓存 */
	let forcePing = (qs().ping == "1");
	/* 2 秒短缓存：命中时直接返回，避免重复 fork 多个 sh() 并解析日志 */
	if (!forcePing) {
		let cached = shortGet(STATUS_CACHE, SHORT_TTL, lf);
		if (cached != null) return cached;
	}
	let m = ini(INI_DIR + "MMDVM.ini");
	let g = m["General"] ?? {}, inf = m["Info"] ?? {}, mod = m["Modem"] ?? {};
	let dmr = m["DMR"] ?? {};
	let dmrN = m["DMR Network"] ?? {};
	let disp = m["Display"] ?? {};
	/* 屏幕端口按屏幕类型落在不同段（[Nextion] / [OLED] ...），旧版本误写在 [Display] 段的仍兼容读取 */
	let dispSec = dispSectionFor(g.Display);
	let dispPort = (dispSec == null) ? (disp.Port ?? "") : ((m[dispSec] ?? {}).Port ?? "");
	/* HD44780 地址在 ini 的 [HD44780] I2CAddress；OLED 上游无地址键，存在 uci 的 oled_i2c_addr */
	let dispAddr = "";
	if (dispSec == "OLED") dispAddr = trim(sh("uci get mmdvmhost.main.oled_i2c_addr 2>/dev/null"));
	else if (g.Display == "HD44780") dispAddr = (m["HD44780"] ?? {}).I2CAddress ?? "";
	/* I2C 总线号存 uci；可选总线来自 /dev/i2c-* */
	let i2cBus = trim(sh("uci get mmdvmhost.main.i2c_bus 2>/dev/null"));
	let i2cBuses = scanI2cBuses();
	/* 调制解调器的 I2C 总线：ini 里是 /dev/i2c-N，界面只显示 N */
	let modemBus = replace(mod.I2CPort ?? "", /^.*i2c-/, "");
	if (match(modemBus, /^[0-9]+$/) == null) modemBus = "";
	/* 串口自动探测：USB/ACM/AMA/HS 四类 */
	let serialPorts = scanSerialPorts();
	let nw = ini(INI_DIR + "DMRGateway.ini") ?? {};
	let st = state();
	/* 直连服务器默认 BrandMeister 4602（未保存过时使用；自定义服务器未填名称时用地址显示） */
	let srvAddr = trim(st.dmrServerAddress ?? "");
	if (!length(srvAddr)) srvAddr = "4602.master.brandmeister.network";
	let srvName = trim(st.dmrServerName ?? "");
	if (!length(srvName)) srvName = length(trim(st.dmrServerAddress ?? "")) ? srvAddr : "BrandMeister 4602";
	let srvPort = trim(st.dmrServerPort ?? "");
	if (!length(srvPort)) srvPort = "62031";
	let srvPass = trim(st.dmrServerPassword ?? "");
	if (!length(srvPass)) srvPass = "passw0rd";
	let dmrIds = [];
	let saved = st.dmrIds;
	if (type(saved) == "array") {
		for (let i = 0; i < 5; i++) {
			let it = saved[i] ?? {};
			push(dmrIds, { id: trim(it.id ?? ""), essid: trim(it.essid ?? "") });
		}
	} else {
		/* 旧数据迁移：从 MMDVM.ini / DMRGateway.ini 还原一次并持久化 */
		let dmrEssids = st.dmrEssid ?? [];
		for (let i = 1; i <= 5; i++) {
			let sec = nw["DMR Network " + i] ?? {};
			let raw = (i == 1) ? (length(dmr.Id ?? "") ? dmr.Id : (g.Id ?? "")) : (sec.Id ?? "");
			let es = dmrEssids[i - 1] ?? "";
			let base = raw;
			if (length(es) == 2 && length(raw) > 2 && substr(raw, length(raw) - 2) == es) base = substr(raw, 0, length(raw) - 2);
			else if (length(raw) == 9) { base = substr(raw, 0, 7); es = substr(raw, 7, 2); }
			else es = "";
			push(dmrIds, { id: base, essid: es });
		}
		st.dmrIds = dmrIds;
		saveState(st);
	}
	/* 已启用的 DMR 网络及其连接状态
	   网关模式：从 DMRGateway 日志推断各网络；
	   直连模式：只显示 MMDVM.ini 当前连接的服务器，状态看 MMDVMHost 日志 */
	let dmrType = lc(trim(dmrN.Type ?? "Gateway"));
	let mmdvmRunning = length(trim(sh("pidof MMDVMHost 2>/dev/null"))) > 0;
	let gwRunning = length(trim(sh("pidof DMRGateway 2>/dev/null"))) > 0;
	let mlog = length(lf) ? (FS.readfile(lf) ?? "") : "";
	if (length(mlog) > 120000) mlog = substr(mlog, length(mlog) - 120000);
	/* MMDVMHost 是否真的就绪：最后一次 “Opening the MMDVM” 之后要能走到
	   “Starting protocol handlers”；若只出现读固件失败，说明射频板没起来 */
	let mmOk = mmdvmRunning;
	if (mmOk && length(mlog)) {
		let segs = split(mlog, "Opening the MMDVM");
		let after = (length(segs) > 1) ? segs[length(segs) - 1] : "";
		if (index(after, "Unable to read the firmware") >= 0 && index(after, "Starting protocol handlers") < 0) mmOk = false;
	}
	let nets = [], netAddr = {};
	if (dmrType == "direct") {
		let nm = srvName;
		if (!length(nm)) nm = trim(dmrN.Name ?? "");
		if (!length(nm)) nm = srvAddr;
		if (!length(nm)) nm = "DMR";
		push(nets, { name: nm, connected: false, ping: null });
		let ra = trim(dmrN.RemoteAddress ?? "");
		netAddr[nm] = length(ra) ? ra : srvAddr;
		if (mmOk) nets[0].connected = directConnected(lf);
	} else {
		for (let i = 1; i <= 5; i++) {
			let sec = nw["DMR Network " + i] ?? {};
			if (trim(sec.Enabled ?? "") == "1") {
				let nm = trim(sec.Name ?? "");
				if (length(nm)) {
					push(nets, { name: nm, connected: false, ping: null });
					netAddr[nm] = trim(sec.Address ?? "");
				}
			}
		}
	}
	let gwLog = logFileFor("DMRGateway");
	let gwData = length(gwLog) ? (FS.readfile(gwLog) ?? "") : "";
	if (length(gwData) > 80000) gwData = substr(gwData, length(gwData) - 80000);
	if (dmrType != "direct") {
		for (let l in split(gwData, "\n")) {
			for (let n in nets) {
				if (index(l, " " + n.name + ", ") < 0) continue;
				if (index(l, "Logged into the master successfully") >= 0) n.connected = true;
				else if (index(l, "Connection to the master has timed out") >= 0) n.connected = false;
				else if (index(l, "Closing DMR Network") >= 0) n.connected = false;
				else if (index(l, "Opening DMR Network") >= 0) n.connected = false;
			}
		}
	}
	/* 网关模式下，MMDVMHost 未就绪或网关没在运行，日志里残留的登录记录不代表当前在线 */
	if (dmrType != "direct" && (!mmOk || !gwRunning)) {
		for (let n in nets) n.connected = false;
	}
	/* 各网络 ping 值：仅在已连接时测试；10 秒缓存（电脑版每 10 秒刷新一次） */
	let pingNow = time(), pc = {}, pingChanged = false;
	try { pc = json(FS.readfile(PING_CACHE) ?? "") ?? {}; } catch (e) { pc = {}; }
	for (let n in nets) {
		let addr = netAddr[n.name] ?? "";
		if (!n.connected || !length(addr)) { n.ping = null; continue; }
		let c = pc[n.name];
		if (forcePing || !c || pingNow - (c.t ?? 0) > 10) {
			let po = sh("ping -c 1 -W 1 " + addr + " 2>/dev/null");
			let ms = between(po, "time=", " ms");
			c = { t: pingNow, ms: (ms != null ? int(ms) : null) };
			pc[n.name] = c;
			pingChanged = true;
		}
		n.ping = c.ms;
	}
	/* 仅在有新 ping 结果时落盘，避免每次状态请求都重写 */
	if (pingChanged) try { FS.writefile(PING_CACHE, sprintf("%J", pc)); } catch (e) {}
	let modes = [];
	if ((m["DMR"] ?? {}).Enable == "1") push(modes, "DMR");
	if ((m["System Fusion"] ?? {}).Enable == "1") push(modes, "YSF");
	if ((m["P25"] ?? {}).Enable == "1") push(modes, "P25");
	if ((m["NXDN"] ?? {}).Enable == "1") push(modes, "NXDN");
	if ((m["D-Star"] ?? {}).Enable == "1") push(modes, "DSTAR");
	let ml = "";
	for (let x in modes) ml += (length(ml) ? "/" : "") + x;

	let curState = "Idle", ver = "MMDVMHost";
	/* 单次遍历同时取最后一条模式切换与首条版本号，避免重复 split 整份日志 */
	let verFound = false;
	for (let l in split(mlog, "\n")) {
		let s = between(l, "Mode set to ", null);
		if (s != null) curState = trim(s);
		if (!verFound) {
			let v = between(l, "MMDVMHost-", " is running");
			if (v != null && length(trim(v))) { ver = "MMDVMHost-" + trim(v); verFound = true; }
		}
	}
	/* 日志按 UTC 日期滚动，跨天后新文件里还没有启动行，用上次解析到的版本兜底；
	   首次（缓存未建立，如刚重启）则回看上一份日志，取最后一次启动的版本 */
	let verCache = FS.readfile("/tmp/dashboard_ver");
	let verCached = (verCache != null) ? trim(verCache) : "";
	if (match(verCached, /^MMDVMHost-[0-9A-Za-z]+$/) == null) verCached = "";
	if (!verFound) {
		if (length(verCached)) {
			ver = verCached;
		} else {
			let prev = trim(sh("ls -t /var/log/mmdvm/MMDVM-*.log 2>/dev/null | sed -n 2p"));
			if (length(prev)) {
				let g = between(sh("grep -o 'MMDVMHost-[0-9A-Za-z]* is running' " + prev + " | tail -1"), "MMDVMHost-", " is running");
				if (g != null && length(trim(g))) {
					ver = "MMDVMHost-" + trim(g);
					try { FS.writefile("/tmp/dashboard_ver", ver + "\n"); } catch (e) {}
				}
			}
		}
	} else if (verCached != ver) {
		try { FS.writefile("/tmp/dashboard_ver", ver + "\n"); } catch (e) {}
	}
	/* DMRGateway 版本：启动行是 “DMRGateway-YYYYMMDD is starting”，跨天兜底同上 */
	let gwVer = "", gwFound = false;
	/* 必须按行匹配：日志里 “DMRGateway-xxx exited on receipt of SIGTERM” 也会出现该前缀，
	   跨行截取会把整段关停日志当作版本号 */
	for (let l in split(gwData, "\n")) {
		if (index(l, " is starting") < 0) continue;
		let v = between(l, "DMRGateway-", " is starting");
		if (v != null && length(trim(v))) { gwVer = "DMRGateway-" + trim(v); gwFound = true; }
	}
	let gwVerCache = FS.readfile("/tmp/dashboard_gwver");
	let gwCached = (gwVerCache != null) ? trim(gwVerCache) : "";
	/* 缓存只接受形如 DMRGateway-20250607 的值，防止旧的脏缓存继续外显 */
	if (match(gwCached, /^DMRGateway-[0-9A-Za-z]+$/) == null) gwCached = "";
	if (!gwFound) {
		if (length(gwCached)) {
			gwVer = gwCached;
		} else {
			/* 当前日志里没有启动行时，回看所有日志，取最后一次启动（文件名按日期递增） */
			let g = between(sh("grep -o 'DMRGateway-[0-9A-Za-z]* is starting' /var/log/mmdvm/DMRGateway-*.log 2>/dev/null | tail -1"), "DMRGateway-", " is starting");
			if (g != null && length(trim(g))) gwVer = "DMRGateway-" + trim(g);
		}
	}
	if (length(gwVer) && (gwVerCache == null || trim(gwVerCache) != gwVer))
		try { FS.writefile("/tmp/dashboard_gwver", gwVer + "\n"); } catch (e) {}

	let body = {
		hostname: hostname(),
		ip: trim(sh("uci get network.lan.ipaddr 2>/dev/null")),
		online: true,
		networks: nets,
		mmdvm: {
			running: mmdvmRunning,
			mode: length(ml) ? ml : "—",
			state: curState,
			callsign: g.Callsign ?? "",
			dmrId: dmrIds[0].id ?? "",
			dmrIds: dmrIds,
			dmrSectionId: dmr.Id ?? "",
			protocol: mod.Protocol ?? "",
			uartPort: mod.UARTPort ?? "",
			uartSpeed: mod.UARTSpeed ?? "",
			serialPorts: serialPorts,
			i2cPort: mod.I2CPort ?? "",
			modemBus: modemBus,
			modemI2cAddr: mod.I2CAddress ?? "",
			modemAddress: mod.ModemAddress ?? "",
			modemPort: mod.ModemPort ?? "",
			screenType: g.Display ?? "",
			screenPort: dispPort,
			screenAddr: dispAddr,
			i2cBus: i2cBus,
			i2cBuses: i2cBuses,
			rxFreq: +inf.RXFrequency || 0,
			txFreq: +inf.TXFrequency || 0,
			power: +inf.Power || 0,
			latitude: inf.Latitude ?? "0.0",
			longitude: inf.Longitude ?? "0.0",
			height: inf.Height ?? "0",
			location: inf.Location ?? "",
			description: inf.Description ?? "",
			url: inf.URL ?? "",
			dmrType: dmrType == "direct" ? "Direct" : "Gateway",
			slot1: dmrN.Slot1 ?? "",
			slot2: dmrN.Slot2 ?? "",
			colorCode: dmr.ColorCode ?? "",
			beacons: dmr.Beacons ?? "",
			beaconInterval: dmr.BeaconInterval ?? "",
			dmrServerName: srvName,
			dmrServerAddress: srvAddr,
			dmrServerPort: srvPort,
			dmrServerPassword: srvPass,
			version: ver,
			gwVersion: gwVer
		}
	};
	shortPut(STATUS_CACHE, body, lf);
	return body;
}

function cmdServices() {
	let r = [];
	for (let s in SVCS) push(r, svcInfo(s));
	out(r);
}

function cmdConfigs() {
	let o = {};
	for (let s in SVCS) {
		let p = INI_DIR + s.ini;
		let c = FS.readfile(p);
		if (c == null) continue;
		o[s.ini] = { path: p, svc: s.key, content: c };
	}
	out(o);
}

function cmdSystem() {
	let mem = FS.readfile("/proc/meminfo") ?? "";
	let total = 0, avail = 0, freeKb = 0, bufKb = 0, cacheKb = 0, reclaimKb = 0;
	for (let l in split(mem, "\n")) {
		if (substr(l, 0, 9) == "MemTotal:") total = +trim(substr(l, index(l, ":") + 1));
		if (substr(l, 0, 13) == "MemAvailable:") avail = +trim(substr(l, index(l, ":") + 1));
		if (substr(l, 0, 8) == "MemFree:") freeKb = +trim(substr(l, index(l, ":") + 1));
		if (substr(l, 0, 8) == "Buffers:") bufKb = +trim(substr(l, index(l, ":") + 1));
		if (substr(l, 0, 7) == "Cached:") cacheKb = +trim(substr(l, index(l, ":") + 1));
		if (substr(l, 0, 13) == "SReclaimable:") reclaimKb = +trim(substr(l, index(l, ":") + 1));
	}
	let la = words(FS.readfile("/proc/loadavg") ?? "");
	let up = int(trim(split(FS.readfile("/proc/uptime") ?? "0", " ")[0]));
	let df = words(sh("df -k / | tail -1"));
	let dTotalKb = +df[1] || 0, dUsedKb = +df[2] || 0, dAvailKb = +df[3] || 0;
	/* CPU 使用率：取 /proc/stat 两次采样的差值，避免单核机器用负载均值长期顶到 100% */
	let st = words(split(FS.readfile("/proc/stat") ?? "", "\n")[0] ?? "");
	let cTotal = 0, cIdle = 0;
	for (let i = 1; i < length(st); i++) {
		let v = +st[i] || 0;
		cTotal += v;
		if (i == 4 || i == 5) cIdle += v;
	}
	let prev = null;
	try { prev = json(FS.readfile(CPU_CACHE) ?? ""); } catch (e) { prev = null; }
	let cpuPct = 0;
	if (type(prev) == "object" && prev != null && prev.total > 0 && cTotal > prev.total) {
		let dt = cTotal - prev.total, di = cIdle - (prev.idle ?? 0);
		cpuPct = (dt > 0) ? rnd((dt - di) * 100 / dt) : 0;
	} else if (cTotal > 0) {
		/* 首次启动后没有历史采样时，用开机以来的平均值 */
		cpuPct = rnd((cTotal - cIdle) * 100 / cTotal);
	}
	if (cpuPct < 0) cpuPct = 0;
	if (cpuPct > 100) cpuPct = 100;
	try { FS.writefile(CPU_CACHE, sprintf("%J", { total: cTotal, idle: cIdle })); } catch (e) {}
	let totalMb = rnd(total / 1024);
	/* 已用内存按 free 的算法：总量 - 空闲 - 缓冲 - 缓存 - 可回收，避免把缓存算进已用 */
	let usedKb = total - freeKb - bufKb - cacheKb - reclaimKb;
	if (usedKb < 0) usedKb = 0;
	let memUsedMb = rnd(usedKb / 1024);
	let inGb = dTotalKb >= 1048576;
	let dTotal = inGb ? +sprintf("%.1f", dTotalKb / 1048576) : rnd(dTotalKb / 1024);
	let dUsed = inGb ? +sprintf("%.1f", dUsedKb / 1048576) : rnd(dUsedKb / 1024);
	let d = int(up / 86400), h = int((up % 86400) / 3600), mi = int((up % 3600) / 60);
	out({
		hostname: hostname(),
		model: trim(FS.readfile("/tmp/sysinfo/model") ?? "—"),
		firmware: trim(sh(". /etc/openwrt_release 2>/dev/null; echo $DISTRIB_DESCRIPTION")),
		kernel: trim(sh("uname -r")),
		uptime: d + "天 " + h + "小时 " + mi + "分",
		load: [ +la[0] || 0, +la[1] || 0, +la[2] || 0 ],
		cpuPct: cpuPct,
		memTotal: totalMb,
		memUsed: memUsedMb,
		memPct: totalMb ? rnd(memUsedMb * 100 / totalMb) : 0,
		diskTotal: dTotal,
		diskUsed: dUsed,
		diskUnit: inGb ? "GB" : "MB",
		/* 百分比与 df 的 Use% 一致：已用 / (已用 + 可用) */
		diskPct: (dUsedKb + dAvailKb) ? rnd(dUsedKb * 100 / (dUsedKb + dAvailKb)) : 0
	});
}

/* ---------- 最近通联持久化 ---------- */
function lhLoad() {
	let st = null;
	try {
		let d = FS.readfile(LH_STORE);
		if (d != null && substr(trim(d), 0, 1) == "{") st = json(d);
	} catch (e) { st = null; }
	if (type(st) != "object" || st == null || type(st.ids) != "object" || st.ids == null)
		st = { ver: 1, since: 0, ids: {} };
	if (type(st.since) != "int") st.since = 0;
	return st;
}
function lhSave(st) { writeCache(LH_STORE, st); }

/* 并入一条记录。key 为聚合键（DMR ID；纯呼号记录用 "C:呼号"）。
   用「该 ID 最后通联时间」做水位去重：日志重启后会重新解析旧内容，
   旧记录的时间不会超过水位，因此不会重复入库。返回是否有新增 */
function lhTouch(st, key, id, call, q) {
	let ts = epochOf(q.ts);
	if (!ts || ts < st.since) return false;
	let e = st.ids[key];
	if (e != null && type(e) == "object" && ts <= (+e.last || 0)) return false;
	if (e == null || type(e) != "object") {
		e = { id: id, call: "", last: 0, rec: null, hist: [] };
		st.ids[key] = e;
	}
	e.id = id;
	if (length(call)) e.call = call;
	e.last = ts;
	e.rec = {
		callsign: q.callsign, isId: q.isId, target: q.target, dir: q.dir,
		slot: q.slot, ts: q.ts, dur: q.dur, ber: q.ber, rssi: q.rssi, gps: q.gps,
		data: q.data ? 1 : 0
	};
	let hist = (type(e.hist) == "array") ? e.hist : [];
	/* 历史只存通话组与时间戳，时间由前端按 ts 格式化，避免重复占用存储 */
	let nh = [{ tg: q.target ?? "", ts: ts, d: q.data ? 1 : 0 }];
	for (let i = 0; i < length(hist) && length(nh) < LH_MAX_HIST; i++) push(nh, hist[i]);
	e.hist = nh;
	return true;
}
/* 超过上限时按最后通联时间淘汰最旧的 ID，避免文件无限增长 */
function lhTrim(st) {
	let arr = [];
	for (let k in st.ids) push(arr, k);
	if (length(arr) <= LH_MAX_IDS) return;
	for (let i = 0; i < length(arr); i++)
		for (let j = i + 1; j < length(arr); j++)
			if ((+st.ids[arr[j]].last || 0) < (+st.ids[arr[i]].last || 0)) {
				let t = arr[i]; arr[i] = arr[j]; arr[j] = t;
			}
	for (let i = 0; i < length(arr) - LH_MAX_IDS; i++) delete st.ids[arr[i]];
}

function cmdLastheard() {
	let file = logFileFor("MMDVM");
	/* 日志与呼号库都没变化时直接返回上次结果（最长 2 分钟刷新一次） */
	let sig = fileSig(file) + "#" + fileSig(INI_DIR + "DMRIds.dat") + "#" +
	          fileSig(BG_CSV) + "#" + fileSig(RW_CSV) + "#" + fileSig(ID_CACHE) + "#" + int(time() / 120);
	let cc = FS.readfile(LH_CACHE);
	if (cc != null && substr(trim(cc), 0, 1) == "{") {
		let v = json(cc);
		if (type(v) == "object" && v.sig == sig && type(v.body) == "array") { out(v.body); return; }
	}
	let recs = parseQso().recs;
	/* 合并阶段只解析 ID：ID 记录用呼号本身，纯呼号记录才查 DMRIds.dat。
	   地址/呼号全表扫描留到展示阶段，只对最终 50 条做，避免每次刷新都扫库 */
	let st = lhLoad();
	let nidCalls = [], seenC = {};
	for (let q in recs) {
		if (q.isId || seenC[q.callsign]) continue;
		seenC[q.callsign] = true;
		push(nidCalls, q.callsign);
	}
	let c2id = length(nidCalls) ? idFor(nidCalls) : {};
	let added = false;
	for (let q in recs) {
		let id = q.isId ? q.callsign : (c2id[q.callsign] ?? "");
		let key = length(id) ? id : ("C:" + q.callsign);
		if (lhTouch(st, key, id, "", q)) { added = true; continue; }
		/* 旧数据迁移：已入库的同一时间戳记录补上 data（APRS 等数据突发）标记 */
		if (!q.data) continue;
		let e = st.ids[key];
		if (e == null || type(e) != "object") continue;
		let qts = epochOf(q.ts), hit = false;
		if (e.rec != null && type(e.rec) == "object" && epochOf(e.rec.ts) == qts && !e.rec.data) {
			e.rec.data = 1; hit = true;
		}
		let hs = (type(e.hist) == "array") ? e.hist : [];
		for (let h in hs) {
			if (h != null && h.ts == qts && !h.d) { h.d = 1; hit = true; }
		}
		if (hit) added = true;
	}
	if (added) { lhTrim(st); lhSave(st); }
	/* 按最后通联时间倒序取前 50 个 ID */
	let keys = [];
	for (let k in st.ids) push(keys, k);
	for (let i = 0; i < length(keys); i++)
		for (let j = i + 1; j < length(keys); j++)
			if ((+st.ids[keys[j]].last || 0) > (+st.ids[keys[i]].last || 0)) {
				let t = keys[i]; keys[i] = keys[j]; keys[j] = t;
			}
	let pick = [];
	for (let i = 0; i < length(keys) && length(pick) < 50; i++) {
		let e = st.ids[keys[i]];
		if (e != null && type(e.rec) == "object" && e.rec != null) push(pick, e);
	}
	/* 只为这 50 条反查呼号 / DMR ID / 地址 */
	let calls = [], idlist = [], seen = {}, seenId = {};
	for (let e in pick) {
		let q = e.rec;
		if (q.isId) {
			if (!seenId[q.callsign]) { seenId[q.callsign] = true; push(idlist, q.callsign); }
		} else if (!seen[q.callsign]) { seen[q.callsign] = true; push(calls, q.callsign); }
	}
	/* 展示阶段：多数呼号已在合并阶段解析，只有旧记录里未覆盖的呼号才补查一次 */
	let ids = c2id;
	let miss = [];
	for (let c in calls) if (ids[c] == null) push(miss, c);
	if (length(miss)) {
		let extra = idFor(miss);
		for (let c in extra) ids[c] = extra[c];
	}
	radiowoSync();
	bgSync();
	let ids46 = [], ids86 = [], otherIds = [];
	for (let x in idlist) {
		if (is46Id(x)) push(ids46, x);
		else if (is86Id(x)) push(ids86, x);
		else push(otherIds, x);
	}
	let id2call = resolveCalls(otherIds);
	let allids = [];
	for (let x in idlist) push(allids, x);
	for (let c in ids) push(allids, ids[c]);
	/* 46 开头用 BG4ESI，86 开头用 radiowo */
	let bg = bgLookup(ids46, calls);
	let rw = rwLookup(ids86, calls);
	for (let k in bg.call) id2call[k] = bg.call[k];
	for (let k in rw.call) id2call[k] = rw.call[k];
	/* 地址合并：BG4ESI 优先（46），radiowo 次之（86），互不妨碍 */
	let addrMap = {};
	for (let k in bg.addrId) addrMap[k] = bg.addrId[k];
	for (let k in rw.addrId) addrMap[k] = rw.addrId[k];
	let addrCall = {};
	for (let k in bg.addrCall) addrCall[k] = bg.addrCall[k];
	for (let k in rw.addrCall) addrCall[k] = rw.addrCall[k];
	/* 呼号→ID 合并（DMRIds.dat 查不到时用数据库反查） */
	let call2id = {};
	for (let k in bg.call2id) call2id[k] = bg.call2id[k];
	for (let k in rw.call2id) call2id[k] = rw.call2id[k];
	let r = [];
	/* 通联记录里的内嵌 GPS：地址只读缓存，未命中交给后台进程查，下一次刷新补上 */
	let inf = (ini(INI_DIR + "MMDVM.ini")["Info"] ?? {});
	let myLat = +trim(inf.Latitude ?? ""), myLon = +trim(inf.Longitude ?? "");
	let hasMe = ((myLat < 0 ? -myLat : myLat) > 0.0001 || (myLon < 0 ? -myLon : myLon) > 0.0001);
	for (let e in pick) {
		let q = e.rec;
		let call = q.callsign, id = "";
		if (q.isId) { call = id2call[q.callsign] ?? e.call ?? ""; id = q.callsign; }
		else id = ids[q.callsign] ?? call2id[q.callsign] ?? (e.id ?? "");
		let g4 = null;
		if (q.gps != null && q.gps.lat && q.gps.lon) {
			let a = addrCached(q.gps.lat, q.gps.lon);
			if (!length(a)) addrPrefetch(q.gps.lat, q.gps.lon);
			let km = hasMe ? distKm(myLat, myLon, q.gps.lat, q.gps.lon) : null;
			g4 = { lat: q.gps.lat, lon: q.gps.lon, addr: a,
				dist: (km != null) ? ((km < 10) ? (rnd(km * 10) / 10) : rnd(km)) : null };
		}
		/* 历史只回传通话组与时间戳（时间由前端按 ts 格式化），减小响应体积 */
		let hist = (type(e.hist) == "array") ? e.hist : [];
		let hout = [];
		for (let h in hist) {
			let o = { tg: h.tg ?? "", ts: h.ts ?? 0 };
			if (h.d) o.d = 1;
			push(hout, o);
		}
		push(r, {
			callsign: call,
			id: id,
			addr: (length(id) && addrMap[id]) ? addrMap[id] : (addrCall[call] ?? ""),
			dir: q.dir,
			mode: q.data ? "DATA" : "DMR",
			slot: q.slot,
			target: q.target,
			rssi: (q.dir == "TX" && q.rssi != null) ? sprintf("%d dBm", q.rssi) : "",
			ber: sprintf("%.1f%%", q.ber),
			dur: sprintf("%.1f", q.dur),
			time: hhmmss(q.ts),
			ts: epochOf(q.ts),
			gps: g4,
			hist: hout
		});
	}
	writeCache(LH_CACHE, { sig: sig, body: r });
	out(r);
}

/* 清除通联记录缓存：保留文件并写入 since 水位，避免日志重新解析后旧记录被再次灌入 */
function cmdLhClear() {
	writeCache(LH_STORE, { ver: 1, since: time(), ids: {} });
	FS.writefile(LH_CACHE, "");
	out({ ok: true });
}

/* ---------- BrandMeister 静态组（API Key 方式） ---------- */
const BM_API = "https://api.brandmeister.network/v2";
/* 当前设备的 DMR ID：优先用静态组页面保存的覆盖值，否则取基础配置里的 DMR ID 1（去掉 ESSID） */
function bmDeviceId() {
	let st = state();
	let ov = trim(st.bmDeviceId ?? "");
	if (length(ov) && match(ov, /^[0-9]{4,9}$/) != null) return ov;
	let ids = st.dmrIds;
	if (type(ids) == "array" && ids[0] != null) {
		let id = trim(ids[0].id ?? "");
		if (length(id)) return id;
	}
	let m = ini(INI_DIR + "MMDVM.ini");
	let raw = trim((m["DMR"] ?? {}).Id ?? "");
	if (length(raw) == 9) raw = substr(raw, 0, 7);
	return raw;
}
function bmKey() { return trim(state().bmApiKey ?? ""); }
/* 调 BM API：method + 路径 + 可选 JSON body，返回 { code, body }。
   查询接口无需鉴权，写入接口需要 API Key（未配置时不带 Authorization） */
function bmReq(method, path, payload) {
	let key = bmKey();
	let cmd = "/usr/bin/curl -s -m 8 -w '\\n%{http_code}' -H 'Accept: application/json'";
	if (length(key)) cmd += " -H 'Authorization: Bearer " + key + "'";
	if (method == "POST") cmd += " -X POST -H 'Content-Type: application/json' --data '" + payload + "'";
	else if (method == "DELETE") cmd += " -X DELETE";
	cmd += " '" + BM_API + path + "' 2>/dev/null";
	let raw = sh(cmd);
	let i = rindex(raw, "\n");
	let code = 0, body = raw;
	if (i >= 0) { code = int(trim(substr(raw, i + 1))); body = substr(raw, 0, i); }
	return { code: code, body: body };
}
function cmdTgGet() {
	let dev = bmDeviceId(), key = bmKey();
	let res = { ok: true, configured: length(key) > 0, deviceId: dev, talkgroups: [], dynamic: [] };
	if (!length(dev)) { out(res); return; }
	/* 配置了 Key 时用 profile 一次拿到静态组 + 动态组；未配置时用公开接口只取静态组 */
	if (length(key)) {
		let pr = bmReq("GET", "/device/" + dev + "/profile", null);
		res.status = pr.code;
		if (pr.code == 200) {
			let p = null;
			try { p = json(pr.body); } catch (e) { p = null; }
			let put = (arr, dst) => {
				if (type(arr) != "array") return;
				for (let x in arr) {
					if (x == null) continue;
					push(dst, { talkgroup: int(x.talkgroup) || 0, slot: int(x.slot) || 0 });
				}
			};
			if (p != null) {
				put(p.staticSubscriptions, res.talkgroups);
				put(p.dynamicSubscriptions, res.dynamic);
			}
			out(res);
			return;
		}
		if (pr.code == 401 || pr.code == 403) { res.ok = false; res.error = "API Key 无效或无权访问该设备"; out(res); return; }
		if (pr.code == 0) { res.ok = false; res.error = "无法连接 BrandMeister（请检查网络）"; out(res); return; }
		/* 其他异常回落到公开接口，至少能看静态组 */
	}
	let r = bmReq("GET", "/device/" + dev + "/talkgroup", null);
	res.status = r.code;
	if (r.code == 0) { res.ok = false; res.error = "无法连接 BrandMeister（请检查网络）"; }
	else if (r.code != 200) { res.ok = false; res.error = "BrandMeister 接口返回 " + r.code; }
	else {
		let arr = null;
		try { arr = json(r.body); } catch (e) { arr = null; }
		if (type(arr) == "array") {
			for (let x in arr) {
				if (x == null) continue;
				push(res.talkgroups, { talkgroup: int(x.talkgroup) || 0, slot: int(x.slot) || 0 });
			}
		}
	}
	out(res);
}
function cmdTgPost() {
	let d = body() ?? {};
	let act = trim(d.act ?? "");
	if (act == "key") {
		let st = state();
		/* 留空表示沿用已保存的密钥，避免误清空 */
		let nk = trim(d.apiKey ?? "");
		if (length(nk)) st.bmApiKey = nk;
		/* DMR ID 允许覆盖（留空则恢复为自动取基础配置的 ID） */
		let ov = trim(d.deviceId ?? "");
		if (length(ov)) {
			if (match(ov, /^[0-9]{4,9}$/) == null) { fail("DMR ID 应为 4~9 位数字"); return; }
			st.bmDeviceId = ov;
		} else {
			delete st.bmDeviceId;
		}
		saveState(st);
		out({ ok: true });
		return;
	}
	/* 清空某个时隙的动态组 */
	if (act == "dropdynamic") {
		let slot = int(d.slot ?? 0);
		if (slot != 1 && slot != 2) { fail("参数不合法"); return; }
		if (!length(bmKey())) { fail("尚未配置 API Key"); return; }
		let dev0 = bmDeviceId();
		if (!length(dev0)) { fail("未找到 DMR ID"); return; }
		let rr = bmReq("GET", "/device/" + dev0 + "/action/dropDynamicGroups/" + slot, null);
		if (rr.code == 0) fail("无法连接 BrandMeister（请检查网络）");
		else if (rr.code == 401 || rr.code == 403) fail("API Key 无效或无权访问该设备");
		else if (rr.code != 200) fail("BrandMeister 接口返回 " + rr.code);
		else out({ ok: true });
		return;
	}
	let tg = int(d.tg ?? 0), slot = int(d.slot ?? 0);
	if (tg <= 0 || tg > 99999999 || (slot != 1 && slot != 2)) { fail("参数不合法"); return; }
	if (!length(bmKey())) { fail("尚未配置 API Key"); return; }
	let dev = bmDeviceId();
	if (!length(dev)) { fail("未找到 DMR ID"); return; }
	let r;
	if (act == "add") r = bmReq("POST", "/device/" + dev + "/talkgroup", "{\"group\":" + tg + ",\"slot\":" + slot + "}");
	else if (act == "del") r = bmReq("DELETE", "/device/" + dev + "/talkgroup/" + slot + "/" + tg, null);
	else { fail("未知操作"); return; }
	if (r.code == 0) fail("无法连接 BrandMeister（请检查网络）");
	else if (r.code == 401 || r.code == 403) fail("API Key 无效或无权访问该设备");
	else if (r.code != 200) fail("BrandMeister 接口返回 " + r.code);
	else out({ ok: true });
}


function cmdLive() {
	let file = logFileFor("MMDVM");
	/* 2 秒短缓存：日志签名未变（无新通话）时直接返回，避免重复反查与 fork */
	let cached = shortGet(LIVE_CACHE, SHORT_TTL, file);
	if (cached != null) return cached;
	let m = ini(INI_DIR + "MMDVM.ini");
	let duplex = (m["General"] ?? {}).Duplex == "1";
	let modes = [];
	if ((m["DMR"] ?? {}).Enable == "1") push(modes, "DMR");
	if ((m["System Fusion"] ?? {}).Enable == "1") push(modes, "YSF");
	if ((m["P25"] ?? {}).Enable == "1") push(modes, "P25");
	if ((m["NXDN"] ?? {}).Enable == "1") push(modes, "NXDN");
	let q = parseQso(file);
	let now = time();
	let slots = { "1": { active: false }, "2": { active: false } };
	let act = {}, startTs = {};

	/* 正在发射/接收（有 header 尚未 end）；APRS 等数据突发只在通联记录里显示 */
	for (let k in q.pend) {
		let p = q.pend[k];
		if (p.data) continue;
		let ts = epochOf(p.ts);
		if (!ts || now - ts > 600) continue;
		/* 日志偶发缺 end 行时，靠“最后一次活动”判断是否已经松手：
		   本机 RF 发射每 60ms 有音频统计行，5 秒无新行即视为结束；
		   网络下行通话中间可能几十秒没有任何日志行（只有收尾的 end 或看门狗行），
		   因此给它更长的兜底时间，避免长通话中途被误判为空闲 */
		let seenMap = (type(q.seen) == "object" && q.seen != null) ? q.seen : {};
		let ats = epochOf(seenMap[k] ?? ((q.rt[k] != null) ? q.rt[k].ts : ""));
		let limit = (p.dir == "RX") ? 180 : 5;
		if (ats && now - ats > limit) continue;
		act[k] = { p: p, ts: ts };
	}

	/* 刚结束的通话再展示 8 秒，避免一松 PTT 就什么都看不到 */
	let last = {};
	let recs = q.recs;
	for (let i = length(recs) - 1; i >= 0; i--) {
		let r = recs[i];
		if (r.data) continue;   /* 数据突发不进实时通联 */
		let key = r.slot ?? "1";
		if (act[key] || last[key]) continue;
		let ts = epochOf(r.ts);
		/* 用「结束时刻」判断新旧：长通话的开始时间可能早于窗口起点，用开始时间会把刚结束的通话丢掉 */
		let ets = ts + (r.dur ?? 0);
		if (!ts || now - ets > 8) break;
		last[key] = { r: r, ts: ts };
	}

	/* 批量反查呼号 / DMR ID */
	let calls = [], idlist = [], seen = {}, seenId = {};
	for (let k in act) {
		let c = act[k].p;
		if (c.isId) { if (!seenId[c.callsign]) { seenId[c.callsign] = 1; push(idlist, c.callsign); } }
		else if (!seen[c.callsign]) { seen[c.callsign] = 1; push(calls, c.callsign); }
	}
	for (let k in last) {
		let c = last[k].r;
		if (c.isId) { if (!seenId[c.callsign]) { seenId[c.callsign] = 1; push(idlist, c.callsign); } }
		else if (!seen[c.callsign]) { seen[c.callsign] = 1; push(calls, c.callsign); }
	}
	let ids = idFor(calls);
	radiowoSync();
	bgSync();
	let ids46 = [], ids86 = [], otherIds = [];
	for (let x in idlist) {
		if (is46Id(x)) push(ids46, x);
		else if (is86Id(x)) push(ids86, x);
		else push(otherIds, x);
	}
	let id2call = resolveCalls(otherIds);
	let allids = [];
	for (let x in idlist) push(allids, x);
	for (let c in ids) push(allids, ids[c]);
	/* 46 开头用 BG4ESI，86 开头用 radiowo */
	let bg = bgLookup(ids46, calls);
	let rw = rwLookup(ids86, calls);
	for (let k in bg.call) id2call[k] = bg.call[k];
	for (let k in rw.call) id2call[k] = rw.call[k];
	/* 地址合并：BG4ESI 优先（46），radiowo 次之（86），互不妨碍 */
	let addrMap = {};
	for (let k in bg.addrId) addrMap[k] = bg.addrId[k];
	for (let k in rw.addrId) addrMap[k] = rw.addrId[k];
	let addrCall = {};
	for (let k in bg.addrCall) addrCall[k] = bg.addrCall[k];
	for (let k in rw.addrCall) addrCall[k] = rw.addrCall[k];

	for (let k in act) {
		let p = act[k].p, ts = act[k].ts;
		startTs[k] = ts;
		let cs = p.isId ? (id2call[p.callsign] ?? "") : p.callsign;
		let did = p.isId ? p.callsign : (ids[p.callsign] ?? "");
		/* 发射中：取当前这次通联最近一个超帧的实时误码率（无数据时为 null） */
		let rtb = null;
		let rti = q.rt[k];
		if (rti != null && epochOf(rti.ts) >= ts - 1) rtb = rti.pct;
		slots[k] = {
			active: true, state: p.dir,
			callsign: cs,
			id: did,
			addr: (length(did) && addrMap[did]) ? addrMap[did] : (addrCall[cs] ?? ""),
			target: p.target,
			rssi: null, ber: rtb, dur: (now > ts) ? now - ts : 0
		};
	}
	for (let k in last) {
		let r = last[k].r;
		startTs[k] = epochOf(r.ts);
		let cs = r.isId ? (id2call[r.callsign] ?? "") : r.callsign;
		let did = r.isId ? r.callsign : (ids[r.callsign] ?? "");
		slots[k] = {
			active: true, ended: true, state: r.dir,
			callsign: cs,
			id: did,
			addr: (length(did) && addrMap[did]) ? addrMap[did] : (addrCall[cs] ?? ""),
			target: r.target,
			rssi: (r.dir == "TX" && r.rssi != null) ? r.rssi : null, ber: r.ber, dur: r.dur
		};
	}
	/* 这次通联里对端上报的内嵌 GPS（APRS）：解析出坐标、逆地理地址、与我这里的距离 */
	let gpss = gpsBySlot(file);
	let inf = m["Info"] ?? {};
	let myLat = +trim(inf.Latitude ?? ""), myLon = +trim(inf.Longitude ?? "");
	let hasMe = ((myLat < 0 ? -myLat : myLat) > 0.0001 || (myLon < 0 ? -myLon : myLon) > 0.0001);
	for (let k in slots) {
		let g = gpss[k];
		if (g == null || !g.lat || !g.lon) continue;
		let st = startTs[k] ?? 0;
		if (st > 0 && g.ts > 0 && g.ts < st) continue;       /* 上一次通联留下的旧坐标 */
		if (g.ts > 0 && now - g.ts > 300) continue;          /* 5 分钟前的坐标不再显示 */
		let d = null;
		if (hasMe) {
			let km = distKm(myLat, myLon, g.lat, g.lon);
			d = (km < 10) ? (rnd(km * 10) / 10) : rnd(km);
		}
		/* 地址只读缓存，未命中就丢给后台进程去查，避免实时接口被网络请求拖慢 */
		let a = addrCached(g.lat, g.lon);
		if (!length(a)) addrPrefetch(g.lat, g.lon);
		slots[k].gps = { lat: g.lat, lon: g.lon, addr: a, dist: d };
	}
	let body = { duplex: duplex, mode: length(modes) ? modes[0] : "DMR", slots: slots };
	shortPut(LIVE_CACHE, body, file);
	return body;
}

/* 由 addrPrefetch 在后台调用：查逆地理并写入缓存，供下一次 /api/live 读取 */
function cmdGeo() {
	let q = qs();
	let la = +(q.lat ?? 0), lo = +(q.lon ?? 0);
	if (!la && !lo) return;
	addrOf(la, lo);
	let mk = "/tmp/dashboard_geo_" + replace(geoKey(la, lo), ",", "_");
	sh("rm -f '" + mk + "'");
}

function cmdCalGet() {
	/* 诊断：记录最近一次轮询页面的 UI 版本，便于确认浏览器是否加载了新前端 */
	let qv = qs();
	if (qv.ui != null && length(qv.ui)) FS.writefile("/tmp/dashboard_ui.txt", qv.ui + " " + (qv.src ?? "-") + " " + time() + "\n");
	let m = ini(INI_DIR + "MMDVM.ini");
	let mod = m["Modem"] ?? {}, inf = m["Info"] ?? {};
	let q = parseQso();
	let recs = q.recs;
	let last = length(recs) ? recs[length(recs) - 1] : null;
	let rssi = null;
	/* 取最近一条带 RSSI 的记录（很多机型不上报，保持 null） */
	for (let i = length(recs) - 1; i >= 0; i--) {
		if (recs[i].rssi != null) { rssi = recs[i].rssi; break; }
	}
	let ber = last ? last.ber : 0;
	/* 发射中优先显示当前超帧的实时 BER */
	let now = time();
	let active = false;
	let rf = false;
	for (let k in q.pend) {
		let e = epochOf(q.pend[k].ts);
		if (e && now - e <= 10) { active = true; break; }
	}
	for (let k in q.rt) {
		let e = epochOf(q.rt[k].ts);
		if (e && now - e <= 5) { active = true; rf = true; ber = q.rt[k].pct; }
	}
	out({
		rxOffset: +mod.RXOffset || 0, txOffset: +mod.TXOffset || 0,
		rxLevel: +mod.RXLevel || 0, txLevel: +mod.TXLevel || 0, rfLevel: +mod.RFLevel || 0,
		rxFrequency: +inf.RXFrequency || 0, txFrequency: +inf.TXFrequency || 0,
		rssi: rssi,
		ber: ber,
		/* 逐突发累计：前端按相邻快照差分，避免漏帧与重复计数 */
		errs: q.cal.errs,
		total: q.cal.total,
		frames: q.cal.frames,
		jumps: q.cal.jumps,
		jsum: q.cal.jsum,
		active: active,
		rf: rf
	});
}
function setIni(file, key, val) {
	sh("sed -i 's|^" + key + "=.*|" + key + "=" + val + "|' " + file);
}
/* 段级写入：只改 [section] 内的 key；无该 key 则插在段内最后一个参数之后；段不存在时追加新段 */
function setIniSec(file, section, key, val) {
	let data = FS.readfile(file) ?? "";
	let lines = split(data, "\n");
	let cur = null, found = false, hasKey = false, lastKv = -1, idx = -1;
	for (let line in lines) {
		idx++;
		let l = trim(line);
		let isSec = (length(l) > 2 && substr(l, 0, 1) == "["
			&& substr(l, length(l) - 1) == "]");
		if (isSec) { cur = substr(l, 1, length(l) - 2); if (cur == section) found = true; continue; }
		if (cur == section) {
			let j = index(l, "=");
			if (j > 0) { if (trim(substr(l, 0, j)) == key) hasKey = true; lastKv = idx; }
		}
	}
	cur = null; idx = -1;
	let txt = "";
	for (let line in lines) {
		idx++;
		let l = trim(line);
		let isSec = (length(l) > 2 && substr(l, 0, 1) == "["
			&& substr(l, length(l) - 1) == "]");
		if (isSec) {
			cur = substr(l, 1, length(l) - 2);
			txt += line + "\n";
			if (cur == section && !hasKey && lastKv < 0) txt += key + "=" + val + "\n";
			continue;
		}
		if (cur == section && hasKey) {
			let i = index(l, "=");
			if (i > 0 && trim(substr(l, 0, i)) == key) { txt += key + "=" + val + "\n"; continue; }
		}
		txt += line + "\n";
		if (cur == section && !hasKey && idx == lastKv) txt += key + "=" + val + "\n";
	}
	if (!found) txt += "\n[" + section + "]\n" + key + "=" + val + "\n";
	if (length(txt)) FS.writefile(file, txt);
}
/* 段级删除：移除 [section] 内的 key；若段因此变空则连段头一并删除 */
function delIniSec(file, section, key) {
	let data = FS.readfile(file);
	if (data == null) return;
	let lines = split(data, "\n");
	let remain = 0, c2 = null;
	for (let line in lines) {
		let l = trim(line);
		if (length(l) > 2 && substr(l, 0, 1) == "[" && substr(l, length(l) - 1) == "]") {
			c2 = substr(l, 1, length(l) - 2); continue;
		}
		if (c2 == section && length(l) && substr(l, 0, 1) != "#" && substr(l, 0, 1) != ";") {
			let j = index(l, "=");
			if (j > 0 && trim(substr(l, 0, j)) == key) continue;
			remain++;
		}
	}
	let cur = null, txt = "";
	for (let line in lines) {
		let l = trim(line);
		let isSec = (length(l) > 2 && substr(l, 0, 1) == "["
			&& substr(l, length(l) - 1) == "]");
		if (isSec) {
			let sn = substr(l, 1, length(l) - 2);
			cur = sn;
			if (sn == section && remain == 0) continue;
			txt += line + "\n"; continue;
		}
		if (cur == section) {
			let i = index(l, "=");
			if (i > 0 && trim(substr(l, 0, i)) == key) continue;
			if (remain == 0 && !length(l)) continue;
		}
		txt += line + "\n";
	}
	if (length(txt)) FS.writefile(file, txt);
}

/* DMRGateway 各 [DMR Network N] 的 Id 只能取自基本信息里配置的 DMR ID（含 ESSID）；
   不在列表里的旧 ID 一律清空，避免网关继续用旧身份登录 */
function syncGwIds(ids) {
	let gw = INI_DIR + "DMRGateway.ini";
	let secs = ini(gw);
	let valid = [];
	for (let it in ids) if (length(it.id)) push(valid, it.id + it.essid);
	for (let k in secs) {
		if (match(k, /^DMR Network [0-9]+$/) == null) continue;
		let cur = trim(secs[k].Id ?? "");
		if (!length(cur)) continue;
		let ok = false;
		for (let v in valid) if (v == cur) { ok = true; break; }
		if (!ok) setIniSec(gw, k, "Id", "");
	}
}

/* ---------- 仪表盘 OTA（只更新网页与 API，不重启） ---------- */
let name = ep();
let method = getenv("REQUEST_METHOD") ?? "GET";
let pi = pathinfo();

const OTA_CONF = "/etc/mmdvm/dashboard-ota.json";
const OTA_DIR = "/tmp/dashboard-ota";
const OTA_CACHE = "/tmp/dashboard-ota-cache.json";
const OTA_DEFAULT_SRC = "https://api.github.com/repos/1083808255/dashboard-ota/contents/dashboard.json";
const DASH_ENDPOINTS = ["basic","calibration","configs","lastheard","lhclear","live","log","ota","page","ports","services","status","system","tg","xlxhosts"];

function sq(s) {
	let t = sprintf("%s", s), o = "";
	for (let i = 0; i < length(t); i++) {
		let ch = substr(t, i, 1);
		o = o + ((ch == "'") ? "'\\''" : ch);
	}
	return "'" + o + "'";
}
function otaConf() {
	let d = FS.readfile(OTA_CONF);
	if (d == null) return {};
	let v = null;
	try { v = json(d); } catch (e) { v = null; }
	return (type(v) == "object" && v != null) ? v : {};
}
function otaSource() { return trim(otaConf().url ?? "") || OTA_DEFAULT_SRC; }
function dashVersion() {
	let v = FS.readfile("/www-dash/VERSION");
	return (v == null) ? "unknown" : (trim(v) || "unknown");
}
function otaFetch(url) {
	/* 用固件自带的 uclient-fetch（curl 不一定预装）；加时间戳参数避开 CDN 缓存 */
	let f = "/tmp/dashboard-ota-manifest.json";
	let u = url + ((index(url, "?") >= 0) ? "&" : "?") + "t=" + time();
	sh("rm -f " + sq(f));
	sh("uclient-fetch -q -T 20 -O " + sq(f) + " " + sq(u) + " 2>/dev/null");
	let o = FS.readfile(f);
	if (o == null || !length(trim(o))) return null;
	let v = null;
	try { v = json(o); } catch (e) { v = null; }
	if (type(v) != "object" || v == null) return null;
	/* GitHub contents API 返回 base64 内容，解码后再解析清单 */
	if (index(url, "api.github.com") >= 0 && v.content != null) {
		let b = "";
		for (let p in split(v.content, "\n")) b = b + trim(p);
		let t = null;
		try { t = b64dec(b); } catch (e) { t = null; }
		if (t == null) return null;
		let m = null;
		try { m = json(t); } catch (e) { m = null; }
		return (type(m) == "object" && m != null) ? m : null;
	}
	return v;
}
/* 清单短时缓存：正常检查走缓存，减少 GitHub API 调用；拉取失败时退回旧缓存 */
function otaCacheGet(ttl, url) {
	let d = FS.readfile(OTA_CACHE);
	if (d == null) return null;
	let v = null;
	try { v = json(d); } catch (e) { v = null; }
	if (type(v) != "object" || v == null) return null;
	if ((v.url ?? "") != url) return null;
	if (ttl > 0 && (time() - (+(v.t ?? 0))) > ttl) return null;
	return (type(v.m) == "object") ? v.m : null;
}
function otaCachePut(url, m) {
	FS.writefile(OTA_CACHE, sprintf("%J", { t: time(), url: url, m: m }) + "\n");
}
function otaManifest(url) {
	let c = otaCacheGet(300, url);
	if (c != null) return c;
	let m = otaFetch(url);
	if (m != null) { otaCachePut(url, m); return m; }
	return otaCacheGet(0, url);
}
/* 清单里的 url 可以是相对路径，按清单地址所在目录拼接 */
function otaAbs(base, u) {
	if (match(u, /^https?:\/\//) != null) return u;
	let i = length(base);
	while (i > 0 && substr(base, i - 1, 1) != "/") i--;
	return substr(base, 0, i) + u;
}
function otaInstallFile(src, dst, mode) {
	sh("cp " + sq(src) + " " + sq(dst + ".new") + " 2>/dev/null");
	let st = FS.stat(dst + ".new");
	if (st == null) return false;
	sh("chmod " + mode + " " + sq(dst + ".new"));
	sh("mv " + sq(dst + ".new") + " " + sq(dst));
	return true;
}
function otaLinks(list) {
	for (let e in list) {
		let n = sprintf("%s", e);
		if (match(n, /^[A-Za-z0-9_-]+$/) == null) continue;
		sh("ln -sf api.uc /www-dash/api/" + n);
	}
}
function otaInstallFrom(dir, endpoints, version) {
	otaInstallFile(dir + "/app.html", "/www-dash/app.html", "0644");
	otaInstallFile(dir + "/index.html", "/www-dash/index.html", "0644");
	otaInstallFile(dir + "/api/api.uc", "/www-dash/api/api.uc", "0755");
	if (length(version)) FS.writefile("/www-dash/VERSION", version + "\n");
	else otaInstallFile(dir + "/VERSION", "/www-dash/VERSION", "0644");
	otaLinks(endpoints);
}
function otaBackup() {
	let f = "/root/dashboard-backup-" + time() + ".tar.gz";
	sh("tar -czf " + sq(f) + " -C /www-dash app.html index.html api/api.uc VERSION 2>/dev/null");
	let st = FS.stat(f);
	return (st != null && st.size > 0) ? f : "";
}
function otaPrune() {
	let out = trim(sh("ls -1t /root/dashboard-backup-*.tar.gz 2>/dev/null"));
	if (!length(out)) return;
	let a = split(out, "\n");
	for (let i = 5; i < length(a); i++) sh("rm -f " + sq(trim(a[i])));
}
/* 版本比较：V0.<数字> 按数字大小比较，其它格式退回字符串比较 */
function otaNewer(a, b) {
	let ma = match(a, /^V0\.([0-9]+)$/);
	let mb = match(b, /^V0\.([0-9]+)$/);
	if (ma != null && mb != null) return +ma[1] > +mb[1];
	return a > b;
}
function cmdOta() {
	let q = qs();
	let act = q.act ?? "info";
	if (act == "info") {
		let c = otaConf();
		out({ ok: true, current: dashVersion(), source: otaSource(), defaultSource: OTA_DEFAULT_SRC,
			last: c.last ?? 0, lastVersion: c.lastVersion ?? "",
			hasBackup: length(trim(sh("ls -1t /root/dashboard-backup-*.tar.gz 2>/dev/null | head -1"))) > 0 });
		return;
	}
	if (act == "seturl") {
		if (method != "POST") return fail("需要 POST");
		let u = trim(q.url ?? "");
		if (match(u, /^https?:\/\/[^\s]+$/) == null) return fail("更新源必须是 http/https 地址");
		let c = otaConf(); c.url = u;
		FS.writefile(OTA_CONF, sprintf("%J", c) + "\n");
		return out({ ok: true, source: u });
	}
	if (act == "check") {
		let src = otaSource();
		let m = otaManifest(src);
		if (m == null) return fail("无法获取更新清单：" + src);
		let cur = dashVersion();
		let latest = trim(m.version ?? "");
		if (!length(latest)) return fail("更新清单缺少 version");
		return out({ ok: true, current: cur, latest: latest,
			updateAvailable: (cur == "unknown") || otaNewer(latest, cur),
			size: m.size ?? 0, notes: m.notes ?? "", source: src });
	}
	if (act == "install") {
		if (method != "POST") return fail("需要 POST");
		let src = otaSource();
		let m = otaManifest(src);
		if (m == null) return fail("无法获取更新清单");
		let u = otaAbs(src, trim(m.url ?? ""));
		if (!length(u)) return fail("更新清单缺少 url");
		let sha = lc(trim(m.sha256 ?? ""));
		if (!length(sha)) return fail("更新清单缺少 sha256");
		sh("rm -rf " + sq(OTA_DIR));
		sh("mkdir -p " + sq(OTA_DIR));
		let pkg = OTA_DIR + "/package.tar.gz";
		sh("uclient-fetch -q -T 120 -O " + sq(pkg) + " " + sq(u) + " 2>/dev/null");
		let st = FS.stat(pkg);
		if (st == null || st.size == 0) return fail("更新包下载失败");
		let want = +m.size || 0;
		if (want > 0 && st.size != want) return fail("更新包大小不匹配");
		let got = lc(trim(split(trim(sh("sha256sum " + sq(pkg))), " ")[0]));
		if (got != sha) return fail("sha256 校验失败");
		/* 只允许更新这几类文件，拒绝包内的其它路径 */
		let lines = split(trim(sh("tar -tzf " + sq(pkg) + " 2>/dev/null")), "\n");
		if (!length(lines)) return fail("更新包损坏");
		let okFiles = ["app.html", "index.html", "api/api.uc", "VERSION"];
		for (let l in lines) {
			let n = trim(replace(l, "./", ""));
			if (!length(n) || substr(n, length(n) - 1, 1) == "/") continue;
			let ok = false;
			for (let a in okFiles) if (a == n) { ok = true; break; }
			if (!ok) return fail("更新包包含非法文件：" + n);
		}
		let stage = OTA_DIR + "/stage";
		sh("mkdir -p " + sq(stage) + " && tar -xzf " + sq(pkg) + " -C " + sq(stage) + " 2>/dev/null");
		let bak = otaBackup();
		let eps = (type(m.endpoints) == "array") ? m.endpoints : DASH_ENDPOINTS;
		otaInstallFrom(stage, eps, trim(m.version ?? ""));
		otaPrune();
		let c = otaConf(); c.last = time(); c.lastVersion = trim(m.version ?? "");
		FS.writefile(OTA_CONF, sprintf("%J", c) + "\n");
		sh("rm -rf " + sq(OTA_DIR));
		return out({ ok: true, version: trim(m.version ?? ""), backup: length(bak) > 0 });
	}
	if (act == "rollback") {
		if (method != "POST") return fail("需要 POST");
		let f = trim(sh("ls -1t /root/dashboard-backup-*.tar.gz 2>/dev/null | head -1"));
		if (!length(f)) return fail("没有可回滚的备份");
		let stage = OTA_DIR + "/rollback";
		sh("rm -rf " + sq(OTA_DIR) + "; mkdir -p " + sq(stage));
		sh("tar -xzf " + sq(f) + " -C " + sq(stage) + " 2>/dev/null");
		otaInstallFrom(stage, DASH_ENDPOINTS, "");
		sh("rm -rf " + sq(OTA_DIR));
		return out({ ok: true, version: dashVersion(), from: f });
	}
	return fail("未知操作");
}

/* ---------- 路由 ---------- */

/* 自动探测：I2C 总线（/dev/i2c-N）与串口（/dev/ttyUSB* 等） */
if (name == "ports") {
	out({ ok: true, serialPorts: scanSerialPorts(), i2cBuses: scanI2cBuses() });
} else if (name == "status") {
	out(cmdStatus());
} else if (name == "services") {
	if (method == "POST") {
		let q = qs();
		let key = "", act = "";
		if (length(pi) > 1) {
			let a = split(substr(pi, 1), "/");
			key = a[0]; act = a[1] ?? "";
		} else {
			key = q.key ?? ""; act = q.act ?? "";
		}
		let s = svcFind(key);
		if (s == null) fail("未知服务");
		else if (act != "start" && act != "stop" && act != "restart" && act != "enable" && act != "disable") fail("未知操作");
		else {
			if (act == "restart" && (q.auto ?? "") == "1") {
				/* 按工作模式编排重启：直连只重启 MMDVMHost 并停止 DMRGateway；网关模式重启两者；未运行则启动 */
				let mi = ini(INI_DIR + "MMDVM.ini") ?? {};
				let net = mi["DMR Network"] ?? {};
				let direct = ((net.Type ?? "Gateway") == "Direct");
				let msgs = "";
				let docmd = (k, a) => sh("/etc/init.d/" + k + " " + a + " >/dev/null 2>&1");
				let onoff = (p) => length(trim(sh("pidof " + p + " 2>/dev/null"))) > 0;
				if (direct) docmd("dmrgateway", "stop");
				else {
					let gwon = onoff("DMRGateway");
					docmd("dmrgateway", gwon ? "restart" : "start");
					msgs = "DMRGateway " + (gwon ? "restarted" : "started");
				}
				let hwon = onoff("MMDVMHost");
				docmd("mmdvmhost", hwon ? "restart" : "start");
				msgs = (length(msgs) ? msgs + "; " : "") + "MMDVMHost " + (hwon ? "restarted" : "started");
				if (direct) msgs = msgs + "; DMRGateway stopped";
				out({ ok: true, output: msgs });
			} else {
				let rc = trim(sh("/etc/init.d/" + key + " " + act + " 2>&1"));
				out({ ok: true, output: rc });
			}
		}
	} else cmdServices();
} else if (name == "configs") {
	if (method == "POST") {
		let q = qs();
		let fn = "";
		if (length(pi) > 1) fn = substr(pi, 1);
		else fn = q.name ?? "";
		if (!match(fn, /^[A-Za-z0-9._ -]+\.ini$/)) fail("非法文件名");
		else {
			let d = body();
			if (d == null || type(d.content) != "string") fail("缺少内容");
			else { FS.writefile(INI_DIR + fn, d.content); out({ ok: true }); }
		}
	} else cmdConfigs();
} else if (name == "xlxhosts") {
	if (method == "POST") {
		let d = body();
		if (d == null || type(d.content) != "string") fail("缺少内容");
		else { FS.writefile(INI_DIR + "XLXHosts.txt", d.content); out({ ok: true }); }
	} else {
		let c = FS.readfile(INI_DIR + "XLXHosts.txt");
		if (c == null) fail("文件不存在");
		else out({ ok: true, content: c });
	}
} else if (name == "ota") {
	cmdOta();
} else if (name == "system") {
	if (method == "POST") {
		let q = qs();
		if ((q.act ?? "") == "reboot") {
			out({ ok: true, message: "rebooting" });
			sh("(sleep 2; reboot) >/dev/null 2>&1 &");
		} else fail("未知操作");
	} else cmdSystem();
} else if (name == "lastheard") {
	cmdLastheard();
} else if (name == "lhclear") {
	cmdLhClear();
} else if (name == "tg") {
	if (method == "POST") cmdTgPost();
	else cmdTgGet();
} else if (name == "live") {
	out(cmdLive());
} else if (name == "geo") {
	cmdGeo();
} else if (name == "calibration") {
	if (method == "POST") {
		let d = body() ?? {};
		setIni(INI_DIR + "MMDVM.ini", "RXOffset", int(d.rxOffset) || 0);
		setIni(INI_DIR + "MMDVM.ini", "TXOffset", int(d.txOffset) || 0);
		setIni(INI_DIR + "MMDVM.ini", "RXLevel", int(d.rxLevel) || 0);
		setIni(INI_DIR + "MMDVM.ini", "TXLevel", int(d.txLevel) || 0);
		setIni(INI_DIR + "MMDVM.ini", "RFLevel", int(d.rfLevel) || 0);
		out({ ok: true });
	} else cmdCalGet();
} else if (name == "basic") {
	if (method == "POST") {
		let d = body() ?? {};
		let cs = trim(d.callsign ?? "");
		/* DMR ID 1~5：每项 { id, essid }，保存在 dashboard.json，只有 ID1 写入 MMDVM.ini */
		let dmrList = d.dmrIds ?? [];
		if (type(dmrList) != "array") dmrList = [];
		let ids = [];
		for (let i = 0; i < 5; i++) {
			let it = dmrList[i] ?? {};
			let vid = trim(it.id ?? ""), ves = trim(it.essid ?? "");
			if (!length(vid)) { push(ids, { id: "", essid: "" }); continue; }
			if (!match(vid, /^[0-9]{1,9}$/)) { fail("DMR ID " + (i + 1) + " 应为数字"); return; }
			if (length(ves) && !match(ves, /^[0-9]{2}$/)) { fail("DMR ID " + (i + 1) + " 的 ESSID 应为两位数字"); return; }
			push(ids, { id: vid, essid: ves });
		}
		if (!length(ids[0].id)) { fail("DMR ID 1 不能为空"); return; }
		/* 仅保存 DMR ID：只记录到 dashboard.json，不写入任何 ini 文件 */
		if (d.dmrOnly) {
			let s1 = state();
			s1.dmrIds = ids;
			saveState(s1);
			syncGwIds(ids);
			out({ ok: true });
			return;
		}
		let id = ids[0].id;
		let proto = trim(d.protocol ?? ""), port = trim(d.uartPort ?? "");
		let speed = trim(d.uartSpeed ?? "");
		let i2cPort = trim(d.i2cPort ?? "");
		let udpAddr = trim(d.udpAddress ?? ""), udpPort = trim(d.udpPort ?? "");
		let screenType = trim(d.screenType ?? ""), screenPort = trim(d.screenPort ?? "");
		let screenAddr = trim(d.screenAddr ?? "");
		let i2cBus = trim(d.i2cBus ?? "");
		let duplex = trim(d.duplex ?? "");
		/* 连接：DMR 网络类型/时隙 + 色码/信标/信标时间 */
		let dmrType = trim(d.dmrType ?? ""), slot1 = trim(d.slot1 ?? ""), slot2 = trim(d.slot2 ?? "");
		let colorCode = trim(d.colorCode ?? ""), beacons = trim(d.beacons ?? ""), beaconInterval = trim(d.beaconInterval ?? "");
		let srvName = trim(d.dmrServerName ?? ""), srvAddr = trim(d.dmrServerAddress ?? ""), srvPort = trim(d.dmrServerPort ?? "");
		let srvPass = trim(d.dmrServerPassword ?? "");
		if (!match(cs, /^[A-Za-z0-9]{3,10}$/)) fail("呼号格式不正确");
		else if (!match(id, /^[0-9]{1,9}$/)) fail("DMR ID 应为数字");
		else {
			let f = INI_DIR + "MMDVM.ini";
			let gw = INI_DIR + "DMRGateway.ini";
			/* 位置信息（Info 段共有字段）校验：纬度/经度为数字，高度为整数 */
			let lat = trim(d.latitude ?? ""), lon = trim(d.longitude ?? ""), hgt = trim(d.height ?? "");
			if (length(lat) && match(lat, /^-?[0-9]+(\.[0-9]+)?$/) == null) { fail("纬度应为数字"); return; }
			if (length(lon) && match(lon, /^-?[0-9]+(\.[0-9]+)?$/) == null) { fail("经度应为数字"); return; }
			if (length(hgt) && match(hgt, /^-?[0-9]+$/) == null) { fail("高度应为整数"); return; }
			/* 连接字段校验 */
			if (length(dmrType) && match(dmrType, /^(Gateway|Direct)$/i) == null) { fail("类型不合法"); return; }
			if (length(slot1) && match(slot1, /^[01]$/) == null) { fail("时隙1 应为 0 或 1"); return; }
			if (length(slot2) && match(slot2, /^[01]$/) == null) { fail("时隙2 应为 0 或 1"); return; }
			if (length(colorCode) && match(colorCode, /^([0-9]|1[0-5])$/) == null) { fail("色码应为 0~15"); return; }
			if (length(beacons) && match(beacons, /^[0-9]$/) == null) { fail("信标应为 0 或 1"); return; }
			if (length(beaconInterval) && (match(beaconInterval, /^[0-9]{1,5}$/) == null || +beaconInterval < 1)) { fail("信标时间应为正整数"); return; }
			/* 服务器地址/端口校验（直连模式使用） */
			if (length(srvAddr) && match(srvAddr, /^[A-Za-z0-9._:-]+$/) == null) { fail("服务器地址不合法"); return; }
			if (length(srvPort) && (match(srvPort, /^[0-9]{1,5}$/) == null || +srvPort < 1 || +srvPort > 65535)) { fail("端口不合法"); return; }
			/* 频率按 MHz 提交，限制在 1~2000MHz，防止误填 Hz 把 ini 写坏（MMDVMHost 会异常） */
			for (let k in ["rxFreq", "txFreq"]) {
				let fv = trim(d[k] ?? "");
				if (!length(fv)) continue;
				if (match(fv, /^[0-9]{1,4}(\.[0-9]{1,6})?$/) == null || +fv < 1 || +fv > 2000) { fail("频率应在 1~2000 MHz（单位 MHz，如 434.500）"); return; }
			}
			setIniSec(f, "General", "Callsign", cs);
			setIniSec(f, "General", "Id", id);
			let rh = rnd((+d.rxFreq || 0) * 1000000);
			let th = rnd((+d.txFreq || 0) * 1000000);
			if (rh > 0) setIniSec(f, "Info", "RXFrequency", rh);
			if (th > 0) setIniSec(f, "Info", "TXFrequency", th);
			/* 位置信息同时写入 MMDVM.ini 与 DMRGateway.ini 的 [Info] 段 */
			let loc = trim(d.location ?? ""), desc = trim(d.description ?? ""), url = trim(d.url ?? "");
			if (length(lat)) { setIniSec(f, "Info", "Latitude", lat); setIniSec(gw, "Info", "Latitude", lat); }
			if (length(lon)) { setIniSec(f, "Info", "Longitude", lon); setIniSec(gw, "Info", "Longitude", lon); }
			if (length(hgt)) { setIniSec(f, "Info", "Height", hgt); setIniSec(gw, "Info", "Height", hgt); }
			if (length(loc)) { setIniSec(f, "Info", "Location", loc); setIniSec(gw, "Info", "Location", loc); }
			if (length(desc)) { setIniSec(f, "Info", "Description", desc); setIniSec(gw, "Info", "Description", desc); }
			if (length(url)) { setIniSec(f, "Info", "URL", url); setIniSec(gw, "Info", "URL", url); }
			/* Duplex：同频 0，异频 1 */
			if (match(duplex, /^[01]$/)) setIniSec(f, "General", "Duplex", duplex);

			/* RF 来源 / UART 端口 / 波特率 → [Modem] */
			if (length(proto) && match(proto, /^(uart|udp|i2c|null)$/))
				setIniSec(f, "Modem", "Protocol", proto);
			else if (length(proto)) fail("RF 来源不合法");
			if (length(port) && match(port, /^\/[A-Za-z0-9._\/-]+$/))
				setIniSec(f, "Modem", "UARTPort", port);
			if (length(speed) && match(speed, /^[0-9]{3,9}$/))
				setIniSec(f, "Modem", "UARTSpeed", speed);
			/* i2c：总线号 → I2CPort=/dev/i2c-N，地址 → I2CAddress；udp：ModemAddress + ModemPort */
			if (length(i2cPort)) {
				let bn = replace(trim(i2cPort), /^\/dev\//, "");
				bn = replace(bn, /^i2c-?/, "");
				if (match(bn, /^[0-9]{1,2}$/) == null) { fail("I2C 总线号应为数字"); return; }
				setIniSec(f, "Modem", "I2CPort", "/dev/i2c-" + bn);
			}
			let modemAddr = trim(d.modemI2cAddr ?? "");
			if (length(modemAddr)) {
				if (match(modemAddr, /^0[xX][0-9A-Fa-f]{2}$/) == null) { fail("调制解调器 I2C 地址应写成 0x22 这样的两位十六进制"); return; }
				setIniSec(f, "Modem", "I2CAddress", "0x" + lc(substr(modemAddr, 2)));
			}
			if (length(udpAddr) && match(udpAddr, /^[A-Za-z0-9._:-]+$/))
				setIniSec(f, "Modem", "ModemAddress", udpAddr);
			if (length(udpPort) && match(udpPort, /^[0-9]{1,5}$/))
				setIniSec(f, "Modem", "ModemPort", udpPort);

			/* 屏幕类型 → [General] Display；屏幕端口 → 对应屏幕段的 Port（[Nextion]/[OLED]/[TFT Serial]） */
			if (length(screenType) && match(screenType, /^(Nextion|HD44780|OLED Type3|OLED Type6|None)$/))
				setIniSec(f, "General", "Display", screenType);
			else if (length(screenType)) fail("屏幕类型不合法");
			let portSec = dispSectionFor(length(screenType) ? screenType : (ini(f)["General"] ?? {}).Display);
			/* Modem：屏幕接在调制解调器的第二串口，MMDVMHost 只认小写 modem */
			let sp = trim(screenPort ?? "");
			let spModem = (lc(sp) == "modem");
			if (length(sp) && (spModem || match(sp, /^\/[A-Za-z0-9._\/-]+$/))) {
				if (portSec == null) fail("当前屏幕类型没有端口可写");
				setIniSec(f, portSec, "Port", spModem ? "modem" : sp);
			} else if (length(sp)) {
				fail("屏幕端口格式不合法");
			} else if (portSec != null) {
				delIniSec(f, portSec, "Port");
			}
			/* 旧版本写错的 [Display] 段一并清理 */
			delIniSec(f, "Display", "Port");

			/* 当前屏幕类型（表单未带时回落到 ini 里的 Display） */
			let curDisp = length(screenType) ? screenType : ((ini(f)["General"] ?? {}).Display ?? "");
			let isI2C = (curDisp == "HD44780" || dispSectionFor(curDisp) == "OLED");
			/* I2C 总线号 → uci（init 脚本转成 MMDVM_I2C_BUS） */
			if (isI2C && length(i2cBus)) {
				if (match(i2cBus, /^[0-9]{1,2}$/) == null) { fail("I2C 总线号应为数字"); return; }
				sh("uci set mmdvmhost.main.i2c_bus='" + i2cBus + "' && uci commit mmdvmhost");
			}
			/* I2C 地址：HD44780 写 ini；OLED 无对应 ini 键，改写 uci（init 转成环境变量给驱动） */
			if (isI2C && length(screenAddr)) {
				if (match(screenAddr, /^0[xX][0-9A-Fa-f]{2}$/) == null) { fail("I2C 地址应写成 0x27 这样的两位十六进制"); return; }
				let addrVal = "0x" + lc(substr(screenAddr, 2));
				if (curDisp == "HD44780")
					setIniSec(f, "HD44780", "I2CAddress", addrVal);
				else
					sh("uci set mmdvmhost.main.oled_i2c_addr='" + addrVal + "' && uci commit mmdvmhost");
			}

			/* DMR ID 1~5（含 ESSID）保存到 dashboard.json；只把 DMR ID 1 写入 MMDVM.ini */
			setIniSec(f, "DMR", "Id", ids[0].id + ids[0].essid);
			/* 连接：类型/时隙 → [DMR Network]；色码/信标/信标时间 → [DMR] */
			if (length(dmrType)) setIniSec(f, "DMR Network", "Type", dmrType);
			if (length(slot1)) setIniSec(f, "DMR Network", "Slot1", slot1);
			if (length(slot2)) setIniSec(f, "DMR Network", "Slot2", slot2);
			if (length(colorCode)) setIniSec(f, "DMR", "ColorCode", colorCode);
			if (length(beacons)) setIniSec(f, "DMR", "Beacons", beacons);
			if (length(beaconInterval)) setIniSec(f, "DMR", "BeaconInterval", beaconInterval);
			/* 网关模式：MMDVM.ini 的 [DMR Network] 指向本机 DMRGateway；直连模式连到所选服务器 */
			if (dmrType == "Gateway") {
				setIniSec(f, "DMR Network", "Enable", "1");
				setIniSec(f, "DMR Network", "LocalAddress", "127.0.0.1");
				setIniSec(f, "DMR Network", "LocalPort", "62032");
				setIniSec(f, "DMR Network", "RemoteAddress", "127.0.0.1");
				setIniSec(f, "DMR Network", "RemotePort", "62031");
				/* 网关模式：本机 DMRGateway 链路密码固定为 passw0rd */
				setIniSec(f, "DMR Network", "Password", "passw0rd");
			} else if (dmrType == "Direct") {
				setIniSec(f, "DMR Network", "Enable", "1");
				if (length(srvAddr)) setIniSec(f, "DMR Network", "RemoteAddress", srvAddr);
				if (length(srvPort)) setIniSec(f, "DMR Network", "RemotePort", srvPort);
				/* 密码：留空时使用默认 passw0rd */
				let netPass = length(srvPass) ? srvPass : "passw0rd";
				if (match(netPass, /^[A-Za-z0-9!@#$%^&*._\-]{1,64}$/) != null)
					setIniSec(f, "DMR Network", "Password", netPass);
				/* 直连不能再绑定回环本地地址，清空以使用默认绑定 */
				delIniSec(f, "DMR Network", "LocalAddress");
				delIniSec(f, "DMR Network", "LocalPort");
			}
			let st = state();
			st.dmrIds = ids;
			st.dmrServerName = srvName;
			st.dmrServerAddress = srvAddr;
			st.dmrServerPort = srvPort;
			st.dmrServerPassword = srvPass;
			saveState(st);
			syncGwIds(ids);
			/* 配置变更后立即失效短缓存与 ping 缓存，避免右上角/电台信息仍显示旧服务器 */
			try { FS.writefile(STATUS_CACHE, ""); } catch (e) {}
			try { FS.writefile(PING_CACHE, "{}"); } catch (e) {}
			out({ ok: true });
		}
	} else out(cmdStatus());
} else if (name == "log") {
	let q = qs();
	let svc = q.service ?? "MMDVMHost";
	let prefix = "MMDVM";
	if (svc == "DMRGateway") prefix = "DMRGateway";
	let file = logFileFor(prefix);
	if (!length(file)) out({ next: 0, lines: [] });
	else {
		let total = int(trim(sh("wc -l < " + file))) || 0;
		let since = int(q.since ?? 0) || 0;
		if (since <= 0) since = (total > 200) ? total - 200 : 0;
		else if (since > total) since = total;
		let txt = sh("tail -n +" + (since + 1) + " " + file + " | head -300");
		let lines = [];
		for (let l in split(txt, "\n")) if (length(trim(l))) push(lines, l);
		out({ next: total, lines: lines });
	}
} else if (name == "page") {
	/* 用 CGI 输出 HTML 并强制 no-store，彻底避免浏览器缓存旧版本界面 */
	let html = FS.readfile("/www-dash/app.html");
	if (html == null) fail("页面不存在");
	else {
		print("Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store, no-cache, must-revalidate\r\nPragma: no-cache\r\n\r\n");
		print(html);
	}
} else {
	fail("未知接口");
}
