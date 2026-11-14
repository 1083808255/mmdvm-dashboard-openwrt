#!/usr/bin/ucode
/* MMDVM Dashboard API —— uhttpd CGI 入口，URL: /api/<endpoint> */
let FS = require("fs");

const INI_DIR = "/etc/mmdvm/";
const STATE   = "/etc/mmdvm/dashboard.json";
const QSO_CACHE = "/tmp/dashboard_qso.cache";
const LH_CACHE  = "/tmp/dashboard_lh.cache";
const STATUS_CACHE = "/tmp/dashboard_status.cache";
const LIVE_CACHE   = "/tmp/dashboard_live.cache";
const PING_CACHE   = "/tmp/dashboard_ping.json";
const CONN_CACHE   = "/tmp/dashboard_conn.cache";
/* 短缓存有效期（秒）：仅用于 status / live 这类高频接口 */
const SHORT_TTL = 2;

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
	let v = json(b);
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
/* 短缓存：ttl 秒内且来源日志签名未变化时直接复用，命中时不再 fork / 解析日志 */
function shortGet(path, ttl, file) {
	let d = FS.readfile(path);
	if (d == null || substr(trim(d), 0, 1) != "{") return null;
	let v = json(d);
	if (type(v) != "object" || v == null || v.body == null) return null;
	if (time() - (v.t ?? 0) > ttl) return null;
	if (length(file) && (v.file != file || v.sig != fileSig(file))) return null;
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
function logFileFor(prefix) {
	return trim(sh("ls -t /var/log/mmdvm/" + prefix + "-*.log 2>/dev/null | head -1"));
}
/* 直连模式下 MMDVMHost 与 master 的连接状态。
   日志可能上百 KB/小时，登录事件常在文件前部，按增量读取：
   只解析上次记录偏移之后新增的内容，避免每次重复扫描整份日志 */
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
function parseQso(logfile) {
	let file = logfile ?? logFileFor("MMDVM");
	let recs = [], pend = {}, rt = {};
	if (!length(file)) return { recs: recs, pend: pend, rt: rt };
	/* 日志未变化时直接复用上次解析结果，避免每秒重复扫描 150KB 日志 */
	let sig = fileSig(file);
	let c = FS.readfile(QSO_CACHE);
	if (length(sig) && c != null && substr(trim(c), 0, 1) == "{") {
		let v = json(c);
		if (type(v) == "object" && v.sig == sig && type(v.recs) == "array" && type(v.pend) == "object")
			return { recs: v.recs, pend: v.pend, rt: (type(v.rt) == "object") ? v.rt : {} };
	}
	let data = FS.readfile(file);
	if (data == null) return { recs: recs, pend: pend, rt: rt };
	/* 只解析日志尾部，避免整天日志全量扫描 */
	if (length(data) > 150000) data = substr(data, length(data) - 150000);
	for (let line in split(data, "\n")) {
		let slot = slotOf(line);
		if (slot == null) continue;
		/* 发射中每个超帧的实时误码率：DMR Slot 1, audio sequence no. 2, errs: 22/141 (15.6%) */
		if (index(line, "audio sequence no.") >= 0) {
			let pct = between(line, "(", "%)");
			if (pct != null) rt[slot] = { pct: +pct, ts: tsOf(line) };
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
			continue;
		}
		if (index(line, "end of voice transmission") >= 0) {
			let p = pend[slot];
			if (p == null) continue;
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
				rssi: (rssi != null) ? +rssi : null
			});
			delete pend[slot];
		}
	}
	if (length(sig)) writeCache(QSO_CACHE, { sig: sig, recs: recs, pend: pend, rt: rt });
	return { recs: recs, pend: pend, rt: rt };
}

/* ---------- 呼号 <-> DMR ID ---------- */
function idFor(calls) {
	let res = {};
	if (!length(calls)) return res;
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
	let mlog = length(lf) ? (FS.readfile(lf) ?? "") : "";
	if (length(mlog) > 120000) mlog = substr(mlog, length(mlog) - 120000);
	let nets = [], netAddr = {};
	if (dmrType == "direct") {
		let nm = srvName;
		if (!length(nm)) nm = trim(dmrN.Name ?? "");
		if (!length(nm)) nm = srvAddr;
		if (!length(nm)) nm = "DMR";
		push(nets, { name: nm, connected: false, ping: null });
		let ra = trim(dmrN.RemoteAddress ?? "");
		netAddr[nm] = length(ra) ? ra : srvAddr;
		if (mmdvmRunning) nets[0].connected = directConnected(lf);
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
	/* 各网络 ping 值：仅在已连接时测试；10 秒缓存（电脑版每 10 秒刷新一次） */
	let pingNow = time(), pc = {};
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
		}
		n.ping = c.ms;
	}
	try { FS.writefile(PING_CACHE, sprintf("%J", pc)); } catch (e) {}
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
			i2cPort: mod.I2CPort ?? "",
			modemAddress: mod.ModemAddress ?? "",
			modemPort: mod.ModemPort ?? "",
			screenType: g.Display ?? "",
			screenPort: disp.Port ?? "",
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
			aprsServer: st.aprsServer ?? "china.aprs2.net",
			aprsEnable: (st.aprsEnable != null) ? (st.aprsEnable ? 1 : 0) : 1,
			version: ver
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
	let total = 0, avail = 0;
	for (let l in split(mem, "\n")) {
		if (substr(l, 0, 9) == "MemTotal:") total = +trim(substr(l, index(l, ":") + 1));
		if (substr(l, 0, 13) == "MemAvailable:") avail = +trim(substr(l, index(l, ":") + 1));
	}
	let la = words(FS.readfile("/proc/loadavg") ?? "");
	let up = int(trim(split(FS.readfile("/proc/uptime") ?? "0", " ")[0]));
	let df = words(sh("df -k / | tail -1"));
	let dTotalKb = +df[1] || 0, dUsedKb = +df[2] || 0;
	let ncpu = +trim(sh("grep -c ^processor /proc/cpuinfo 2>/dev/null")) || 1;
	let load0 = +la[0] || 0;
	let totalMb = rnd(total / 1024);
	let memUsedMb = rnd((total - avail) / 1024);
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
		cpuPct: (ncpu > 0) ? (load0 / ncpu * 100 > 100 ? 100 : rnd(load0 / ncpu * 100)) : 0,
		memTotal: totalMb,
		memUsed: memUsedMb,
		memPct: totalMb ? rnd(memUsedMb * 100 / totalMb) : 0,
		diskTotal: dTotal,
		diskUsed: dUsed,
		diskUnit: inGb ? "GB" : "MB",
		diskPct: dTotalKb ? rnd(dUsedKb * 100 / dTotalKb) : 0
	});
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
	let n = length(recs);
	let slice = [];
	for (let i = n - 1; i >= 0 && length(slice) < 50; i--) push(slice, recs[i]);
	let calls = [], idlist = [], seen = {}, seenId = {};
	for (let q in slice) {
		if (q.isId) {
			if (!seenId[q.callsign]) { seenId[q.callsign] = true; push(idlist, q.callsign); }
		} else if (!seen[q.callsign]) { seen[q.callsign] = true; push(calls, q.callsign); }
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
	/* 呼号→ID 合并（DMRIds.dat 查不到时用数据库反查） */
	let call2id = {};
	for (let k in bg.call2id) call2id[k] = bg.call2id[k];
	for (let k in rw.call2id) call2id[k] = rw.call2id[k];
	let r = [];
	for (let q in slice) {
		let call = q.callsign, id = "";
		if (q.isId) { call = id2call[q.callsign] ?? ""; id = q.callsign; }
		else id = ids[q.callsign] ?? call2id[q.callsign] ?? "";
		push(r, {
			callsign: call,
			id: id,
			addr: (length(id) && addrMap[id]) ? addrMap[id] : (addrCall[call] ?? ""),
			dir: q.dir,
			mode: "DMR",
			slot: q.slot,
			target: q.target,
			rssi: (q.dir == "TX" && q.rssi != null) ? sprintf("%d dBm", q.rssi) : "",
			ber: sprintf("%.1f%%", q.ber),
			dur: sprintf("%.1f", q.dur),
			time: hhmmss(q.ts),
			ts: epochOf(q.ts)
		});
	}
	writeCache(LH_CACHE, { sig: sig, body: r });
	out(r);
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
	let act = {};

	/* 正在发射/接收（有 header 尚未 end） */
	for (let k in q.pend) {
		let p = q.pend[k];
		let ts = epochOf(p.ts);
		if (!ts || now - ts > 600) continue;
		act[k] = { p: p, ts: ts };
	}

	/* 若刚结束（3 秒内）仍展示最后一笔，避免界面闪断 */
	let last = {};
	let recs = q.recs;
	for (let i = length(recs) - 1; i >= 0; i--) {
		let r = recs[i];
		let key = r.slot ?? "1";
		if (act[key] || last[key]) continue;
		let ts = epochOf(r.ts);
		if (!ts || now - ts > 3) break;
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
		let cs = r.isId ? (id2call[r.callsign] ?? "") : r.callsign;
		let did = r.isId ? r.callsign : (ids[r.callsign] ?? "");
		slots[k] = {
			active: true, state: r.dir,
			callsign: cs,
			id: did,
			addr: (length(did) && addrMap[did]) ? addrMap[did] : (addrCall[cs] ?? ""),
			target: r.target,
			rssi: (r.dir == "TX" && r.rssi != null) ? r.rssi : null, ber: r.ber, dur: r.dur
		};
	}
	let body = { duplex: duplex, mode: length(modes) ? modes[0] : "DMR", slots: slots };
	shortPut(LIVE_CACHE, body, file);
	return body;
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

/* ---------- 路由 ---------- */
let name = ep();
let method = getenv("REQUEST_METHOD") ?? "GET";
let pi = pathinfo();

if (name == "status") {
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
} else if (name == "live") {
	out(cmdLive());
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
			out({ ok: true });
			return;
		}
		let id = ids[0].id;
		let proto = trim(d.protocol ?? ""), port = trim(d.uartPort ?? "");
		let speed = trim(d.uartSpeed ?? "");
		let i2cPort = trim(d.i2cPort ?? "");
		let udpAddr = trim(d.udpAddress ?? ""), udpPort = trim(d.udpPort ?? "");
		let screenType = trim(d.screenType ?? ""), screenPort = trim(d.screenPort ?? "");
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
			/* i2c：I2CPort；udp：ModemAddress + ModemPort */
			if (length(i2cPort) && match(i2cPort, /^\/[A-Za-z0-9._\/-]+$/))
				setIniSec(f, "Modem", "I2CPort", i2cPort);
			if (length(udpAddr) && match(udpAddr, /^[A-Za-z0-9._:-]+$/))
				setIniSec(f, "Modem", "ModemAddress", udpAddr);
			if (length(udpPort) && match(udpPort, /^[0-9]{1,5}$/))
				setIniSec(f, "Modem", "ModemPort", udpPort);

			/* 屏幕类型 → [General] Display；屏幕端口 → [Display] Port */
			if (length(screenType) && match(screenType, /^(Nextion|HD44780|OLED Type3|OLED Type6|None)$/))
				setIniSec(f, "General", "Display", screenType);
			else if (length(screenType)) fail("屏幕类型不合法");
			if (length(screenPort) && match(screenPort, /^\/[A-Za-z0-9._\/-]+$/))
				setIniSec(f, "Display", "Port", screenPort);
			else if (!length(screenPort))
				delIniSec(f, "Display", "Port");

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
			if (length(d.aprsServer ?? "")) st.aprsServer = d.aprsServer;
			if (d.aprsEnable != null) st.aprsEnable = d.aprsEnable ? 1 : 0;
			saveState(st);
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
