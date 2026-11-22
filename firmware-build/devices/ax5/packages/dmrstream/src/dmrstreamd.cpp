// dmrstreamd: 旁路抓取 MMDVMHost<->DMRGateway 的 DMRD 语音包，
// 按通联分路，AMBE+2(2450) 解码为 8kHz PCM，通过 WebSocket 推送给仪表盘。
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cerrno>
#include <string>
#include <vector>
#include <map>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <sys/select.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <linux/if_packet.h>
#include <net/ethernet.h>
#include <net/if.h>

#define USE_DMR
#include "AMBEFEC.cpp"
#include "Golay24128.h"
extern "C" {
#include <mbelib-neo/mbelib.h>
}
#include "Utils.h"
unsigned int CUtils::countBits(unsigned int v) {
	unsigned int c = 0;
	while (v) { c += (v & 1U); v >>= 1U; }
	return c;
}

// ---------------- AMBE 解码 ----------------
static inline int bitAt(const unsigned char* b, unsigned int pos) {
	return (b[pos >> 3] & (0x80 >> (pos & 7))) ? 1 : 0;
}
static unsigned int grab(const unsigned char* bytes, const unsigned int* tbl, int n, int sub) {
	unsigned int v = 0;
	for (int i = 0; i < n; i++) {
		unsigned int p = tbl[i];
		if (sub == 1) { p += 72U; if (p >= 108U) p += 48U; }
		else if (sub == 2) { p += 192U; }
		v = (v << 1) | (unsigned int)bitAt(bytes, p);
	}
	return v;
}
// 从 33 字节 DMR 帧的某个子帧取出 49 位 AMBE 参数（A/B 先做 Golay 纠错与去扰）
static void extract49(const unsigned char* voice, int sub, char d49[49], int& errBits) {
	unsigned int a = grab(voice, DMR_A_TABLE, 24, sub);
	unsigned int b = grab(voice, DMR_B_TABLE, 23, sub);
	unsigned int c = grab(voice, DMR_C_TABLE, 25, sub);
	unsigned int adata = 0;
	CGolay24128::decode24128(a, adata);
	unsigned int p = PRNG_TABLE[adata] >> 1;
	unsigned int bdata = CGolay24128::decode23127(b ^ p);
	unsigned int reA = CGolay24128::encode24128(adata);
	unsigned int reB = CGolay24128::encode23127(bdata) >> 1;
	errBits += (int)CUtils::countBits(a ^ reA) + (int)CUtils::countBits((b ^ p) ^ reB);
	int k = 0;
	for (int j = 11; j >= 0; j--) d49[k++] = (adata >> j) & 1;
	for (int j = 11; j >= 0; j--) d49[k++] = (bdata >> j) & 1;
	for (int j = 24; j >= 0; j--) d49[k++] = (c >> j) & 1;
}

// ---------------- SHA1 / base64（WebSocket 握手用） ----------------
static void sha1(const unsigned char* data, size_t len, unsigned char out[20]) {
	uint32_t h[5] = {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0};
	std::vector<unsigned char> m(data, data + len);
	uint64_t bits = (uint64_t)len * 8;
	m.push_back(0x80);
	while ((m.size() % 64) != 56) m.push_back(0);
	for (int i = 7; i >= 0; i--) m.push_back((unsigned char)(bits >> (i * 8)));
	for (size_t off = 0; off < m.size(); off += 64) {
		uint32_t w[80];
		for (int i = 0; i < 16; i++)
			w[i] = (m[off + i * 4] << 24) | (m[off + i * 4 + 1] << 16) | (m[off + i * 4 + 2] << 8) | m[off + i * 4 + 3];
		for (int i = 16; i < 80; i++) {
			uint32_t v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
			w[i] = (v << 1) | (v >> 31);
		}
		uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
		for (int i = 0; i < 80; i++) {
			uint32_t f, k2;
			if (i < 20) { f = (b & c) | ((~b) & d); k2 = 0x5A827999; }
			else if (i < 40) { f = b ^ c ^ d; k2 = 0x6ED9EBA1; }
			else if (i < 60) { f = (b & c) | (b & d) | (c & d); k2 = 0x8F1BBCDC; }
			else { f = b ^ c ^ d; k2 = 0xCA62C1D6; }
			uint32_t t = ((a << 5) | (a >> 27)) + f + e + k2 + w[i];
			e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = t;
		}
		h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
	}
	for (int i = 0; i < 5; i++) {
		out[i * 4] = h[i] >> 24; out[i * 4 + 1] = h[i] >> 16; out[i * 4 + 2] = h[i] >> 8; out[i * 4 + 3] = h[i];
	}
}
static std::string base64(const unsigned char* in, size_t n) {
	static const char* T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	std::string s;
	for (size_t i = 0; i < n; i += 3) {
		unsigned v = in[i] << 16;
		if (i + 1 < n) v |= in[i + 1] << 8;
		if (i + 2 < n) v |= in[i + 2];
		s += T[(v >> 18) & 63]; s += T[(v >> 12) & 63];
		s += (i + 1 < n) ? T[(v >> 6) & 63] : '=';
		s += (i + 2 < n) ? T[v & 63] : '=';
	}
	return s;
}

// ---------------- WebSocket ----------------
// wantSlot: 0=自动（跟随最近活跃通联）, 1/2=只收听指定时隙
struct Client { int fd; bool handshaken; int wantSlot; uint64_t curKey; double curSince; double slotStamp; };
static std::vector<Client> clients;

static bool sendAll(int fd, const void* buf, size_t n) {
	const char* p = (const char*)buf;
	while (n) {
		// 非阻塞发送：客户端掉线或读得慢时立刻失败，避免整个进程被 send 卡死
		ssize_t w = ::send(fd, p, n, MSG_NOSIGNAL | MSG_DONTWAIT);
		if (w < 0) {
			if (errno == EINTR) continue;
			return false;
		}
		if (w == 0) return false;
		p += w; n -= (size_t)w;
	}
	return true;
}
static bool wsSend(int fd, int opcode, const void* payload, size_t n) {
	unsigned char hdr[10];
	size_t h = 0;
	hdr[h++] = 0x80 | (unsigned char)opcode;
	if (n < 126) hdr[h++] = (unsigned char)n;
	else if (n <= 65535) { hdr[h++] = 126; hdr[h++] = (n >> 8) & 0xFF; hdr[h++] = n & 0xFF; }
	else return false;
	if (!sendAll(fd, hdr, h)) return false;
	return n == 0 || sendAll(fd, payload, n);
}
static bool wsTextTo(int fd, const char* s) { return wsSend(fd, 1, s, strlen(s)); }

// ---------------- 通联状态 ----------------
struct Call {
	uint32_t stream, src, dst;
	int slot;
	mbe_parms cur, prev, enh;
	std::vector<short> pcm;
	double lastVoice;
	int errBits, frames, lastSeq;
	double lastSeqTime;
	Call() : stream(0), src(0), dst(0), slot(0), lastVoice(0), errBits(0), frames(0), lastSeq(-1), lastSeqTime(0) {
		mbe_initMbeParms(&cur, &prev, &enh);
	}
};
static std::map<uint64_t, Call> calls;
static uint64_t decodeKey = 0;   // 当前正在解码的通联

static double nowSec() {
	struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}
static double lastFlush = 0;
static double lastPing = 0;

// 使用 mbelib-neo 解码一路通联
static void decodeForCall(const unsigned char* voice, Call& c) {
	for (int sub = 0; sub < 3; sub++) {
		char d49[49];
		int e = 0;
		extract49(voice, sub, d49, e);
		c.errBits += e;
		short pcm[160];
		mbe_process_result result = {0};
		int rc = mbe_processAmbe2450Data(pcm, &result, d49, &c.cur, &c.prev, &c.enh);
		if (rc < 0) continue;   // 解码失败的帧直接丢弃
		c.pcm.insert(c.pcm.end(), pcm, pcm + 160);
	}
}

static bool sendCallInfoTo(int fd, const Call& c) {
	char buf[256];
	snprintf(buf, sizeof(buf),
		"{\"type\":\"call\",\"src\":%u,\"dst\":%u,\"slot\":%d,\"stream\":%u}",
		c.src, c.dst, c.slot, c.stream);
	return wsTextTo(fd, buf);
}

/* 解码器只有一个：以最近一次明确选择时隙的客户端为准（自动模式的客户端跟随解码器）。
   这样刷新残留的旧连接、或其它标签页还在别的时隙，都不会把解码器拉走造成静音。 */
static int preferSlot() {
	int s = 0; double best = -1;
	for (auto& cl : clients) {
		if (!cl.handshaken || cl.wantSlot == 0) continue;
		if (cl.slotStamp > best) { best = cl.slotStamp; s = cl.wantSlot; }
	}
	return s;
}

static void handleDMRD(const unsigned char* p, size_t len) {
	if (len < 53) return;
	unsigned char flags = p[15];
	// MMDVMHost: bit7=时隙2，bit6=单呼，bit5=数据帧(其后低 4 位是数据类型)，
	// bit4=语音同步突发，其余为普通语音突发。只有 bit5 置位的才是数据帧，需跳过。
	if (flags & 0x20) return;
	uint32_t src = ((uint32_t)p[5] << 16) | ((uint32_t)p[6] << 8) | p[7];
	uint32_t dst = ((uint32_t)p[8] << 16) | ((uint32_t)p[9] << 8) | p[10];
	uint32_t stream = ((uint32_t)p[16] << 24) | ((uint32_t)p[17] << 16) | ((uint32_t)p[18] << 8) | p[19];
	int slot = (flags & 0x80) ? 2 : 1;
	uint64_t key = ((uint64_t)stream << 32) | ((uint64_t)src << 8) | (uint64_t)slot;
	Call& c = calls[key];
	if (c.stream == 0 && c.src == 0 && c.lastVoice == 0) {
		c.stream = stream; c.src = src; c.dst = dst; c.slot = slot;
	}
	// raw packet socket 在 lo 上会看到 outgoing/host 两份拷贝：同序号且时间极近才算重复
	double t = nowSec();
	if (c.lastSeq == (int)p[4] && t - c.lastSeqTime < 0.3) return;
	c.lastSeq = p[4];
	c.lastSeqTime = t;
	c.lastVoice = t;
	c.frames += 3;

	// 有人收听（自动模式或匹配时隙）才解码，空闲时完全不解码
	bool wanted = false;
	for (auto& cl : clients) {
		if (!cl.handshaken) continue;
		if (cl.wantSlot == 0 || cl.wantSlot == slot) { wanted = true; break; }
	}
	if (!wanted) return;

	/* 所有客户端都锁定了同一个时隙时，解码器优先跟着该时隙。
	   否则两个时隙同时有通话时解码器会被另一路长期占住，选定时隙就一直没声音 */
	int prefer = preferSlot();

	// 解码目标保持稳定：当前目标静音超过 0.8 秒才换路，避免两个时隙的重复流来回切换
	if (decodeKey) {
		auto it = calls.find(decodeKey);
		if (it == calls.end() || t - it->second.lastVoice > 0.8) decodeKey = 0;
		else if (prefer && it->second.slot != prefer) decodeKey = 0;
	}
	if (!decodeKey) {
		double bt = 0;
		for (auto& kv : calls) {
			if (prefer && kv.second.slot != prefer) continue;   /* 锁定指定时隙时不抢别的时隙 */
			if (t - kv.second.lastVoice <= 0.8 && kv.second.lastVoice > bt) { bt = kv.second.lastVoice; decodeKey = kv.first; }
		}
	}
	if (key != decodeKey) return;
	decodeForCall(p + 20, c);
}

static void flushAudio() {
	// 自动模式跟随最近活跃通联；指定时隙时只播该时隙
	uint64_t autoKey = 0;
	double autoT = 0;
	for (auto& kv : calls)
		if (kv.second.lastVoice > autoT) { autoT = kv.second.lastVoice; autoKey = kv.first; }
	// 解码器只处理一路，自动播放跟随它，保证有解码输出的那一路能被听到
	if (decodeKey && calls.count(decodeKey) && nowSec() - calls[decodeKey].lastVoice < 2) autoKey = decodeKey;

	for (size_t i = clients.size(); i-- > 0;) {
		Client& cl = clients[i];
		if (!cl.handshaken) continue;
		uint64_t target = 0;
		if (cl.wantSlot > 0) {
			double bestT = 0;
			for (auto& kv : calls)
				if (kv.second.slot == cl.wantSlot && kv.second.lastVoice > bestT) { bestT = kv.second.lastVoice; target = kv.first; }
			/* 与实际解码的那一路保持一致，避免界面显示「接收中」却听不到声音 */
			if (decodeKey && calls.count(decodeKey)) {
				Call& ec = calls[decodeKey];
				if (ec.slot == cl.wantSlot && nowSec() - ec.lastVoice < 0.8) target = decodeKey;
			}
		} else {
			target = autoKey;
		}
		if (target != cl.curKey) {
			/* 同一通联常同时出现在两个时隙（两个 stream 交替来包，呼号与目标相同），
			   此时保持当前一路，避免每 100ms 来回切换导致前端反复重置音频；
			   真正换人时也至少停留 1 秒，防止两路并发时抖动。 */
			double t = nowSec();
			auto itc = calls.find(cl.curKey);
			if (target && itc != calls.end()) {
				const Call& cur = itc->second;
				const Call& nc = calls[target];
				if (nc.src == cur.src && nc.dst == cur.dst) target = cl.curKey;
				else if (t - cl.curSince < 1.0) target = cl.curKey;
			}
			if (target != cl.curKey) {
				bool ok = target ? sendCallInfoTo(cl.fd, calls[target]) : wsTextTo(cl.fd, "{\"type\":\"end\"}");
				if (!ok) { close(cl.fd); clients.erase(clients.begin() + i); continue; }
				cl.curKey = target;
				cl.curSince = t;
			}
		}
	}

	// 下发音频：每路只发给正在收听它的客户端，无人收听则丢弃，避免缓存堆积
	for (auto& kv : calls) {
		Call& c = kv.second;
		if (c.pcm.size() < 800) continue;   // 攒够 100ms 再发
		for (size_t i = clients.size(); i-- > 0;) {
			Client& cl = clients[i];
			if (!cl.handshaken || cl.curKey != kv.first) continue;
			if (!wsSend(cl.fd, 2, c.pcm.data(), c.pcm.size() * 2)) {
				close(cl.fd);
				clients.erase(clients.begin() + i);
				
			}
		}
		c.pcm.clear();
	}
}

static void reapCalls() {
	double now = nowSec();
	for (auto it = calls.begin(); it != calls.end();) {
		if (now - it->second.lastVoice > 2) {
			if (decodeKey == it->first) decodeKey = 0;
			for (auto& cl : clients)
				if (cl.handshaken && cl.curKey == it->first) {
					wsTextTo(cl.fd, "{\"type\":\"end\"}");
					cl.curKey = 0;
				}
			it = calls.erase(it);
		} else ++it;
	}
}

// 解析浏览器发来的文本帧（客户端帧带掩码），提取 {"type":"slot","slot":N}
static void handleClientFrame(Client& cl, const unsigned char* d, size_t n) {
	if (n < 2) return;
	if ((d[0] & 0x0F) != 1) return;          // 只处理文本帧
	bool masked = (d[1] & 0x80) != 0;
	size_t off = 2, len = d[1] & 0x7F;
	if (len == 126) { if (n < 4) return; len = ((size_t)d[2] << 8) | d[3]; off = 4; }
	else if (len == 127) return;
	unsigned char mask[4] = {0, 0, 0, 0};
	if (masked) { if (n < off + 4) return; memcpy(mask, d + off, 4); off += 4; }
	if (n < off + len) len = n - off;
	if (len >= 200) len = 199;
	char s[200];
	for (size_t k = 0; k < len; k++) s[k] = (char)(d[off + k] ^ mask[k & 3]);
	s[len] = 0;
	const char* sp = strstr(s, "\"slot\"");
	if (!sp) return;
	const char* colon = strchr(sp, ':');
	if (!colon) return;
	int v = atoi(colon + 1);
	if (v < 0 || v > 2) return;
	int oldSlot = cl.wantSlot;
	cl.wantSlot = v;
	cl.slotStamp = nowSec();
	cl.curKey = 0;   // 重新下发通联信息，前端据此切换标题
	cl.curSince = 0;
	/* 切换时隙后立即重新选路：否则解码器可能仍停在原时隙，新时隙会一直没声音。
	   同时先给前端发结束信号，新时隙空闲时界面才能回到「空闲中」 */
	if (v != oldSlot) {
		wsTextTo(cl.fd, "{\"type\":\"end\"}");
		decodeKey = 0;
	}
}

int main(int argc, char** argv) {
	int wsPort = (argc > 1) ? atoi(argv[1]) : 62040;
	const char* ifname = (argc > 2) ? argv[2] : "lo";
	signal(SIGPIPE, SIG_IGN);

	// 抓包 socket
	int pfd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
	if (pfd < 0) { perror("socket(AF_PACKET)"); return 1; }
	// 加大接收缓冲，设备繁忙时不至于丢 DMRD 包（丢包会表现为咔哒/杂音）
	int rcvbuf = 2 * 1024 * 1024;
	setsockopt(pfd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
	struct ifreq ifr; memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	if (ioctl(pfd, SIOCGIFINDEX, &ifr) < 0) { perror("SIOCGIFINDEX"); return 1; }
	struct sockaddr_ll sll; memset(&sll, 0, sizeof(sll));
	sll.sll_family = AF_PACKET; sll.sll_ifindex = ifr.ifr_ifindex; sll.sll_protocol = htons(ETH_P_ALL);
	if (bind(pfd, (struct sockaddr*)&sll, sizeof(sll)) < 0) { perror("bind"); return 1; }

	// WebSocket 监听
	int lfd = socket(AF_INET, SOCK_STREAM, 0);
	int one = 1; setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_ANY); addr.sin_port = htons(wsPort);
	if (bind(lfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) { perror("ws bind"); return 1; }
	listen(lfd, 8);
	fprintf(stderr, "dmrstreamd: capturing on %s, ws port %d\n", ifname, wsPort);

	lastFlush = nowSec();
	for (;;) {
		fd_set rf; FD_ZERO(&rf);
		FD_SET(pfd, &rf); FD_SET(lfd, &rf);
		int maxfd = pfd > lfd ? pfd : lfd;
		for (auto& c : clients) { FD_SET(c.fd, &rf); if (c.fd > maxfd) maxfd = c.fd; }
		struct timeval tv = {0, 100000};
		int r = select(maxfd + 1, &rf, NULL, NULL, &tv);
		if (r < 0 && errno != EINTR) { perror("select"); break; }

		if (FD_ISSET(lfd, &rf)) {
			int cfd = accept(lfd, NULL, NULL);
			if (cfd >= 0) {
				// 读握手
				char req[4096]; size_t got = 0;
				struct timeval tv2 = {1, 0};
				setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv2, sizeof(tv2));
				while (got < sizeof(req) - 1) {
					ssize_t n2 = recv(cfd, req + got, sizeof(req) - 1 - got, 0);
					if (n2 <= 0) break;
					got += (size_t)n2; req[got] = 0;
					if (strstr(req, "\r\n\r\n")) break;
				}
				req[got] = 0;
				char* k = strstr(req, "Sec-WebSocket-Key:");
				if (k) {
					k += 18; while (*k == ' ') k++;
					char key[128]; size_t ki = 0;
					while (*k && *k != '\r' && ki < sizeof(key) - 1) key[ki++] = *k++;
					key[ki] = 0;
					std::string cat = std::string(key) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
					unsigned char dig[20]; sha1((const unsigned char*)cat.data(), cat.size(), dig);
					std::string acc = base64(dig, 20);
					char resp[512];
					snprintf(resp, sizeof(resp),
						"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", acc.c_str());
					if (sendAll(cfd, resp, strlen(resp))) {
						int nd = 1; setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &nd, sizeof(nd));
						/* 握手用的 1 秒读超时必须清掉：浏览器连上后不会主动发数据，
						   留着它会让 recv 每秒返回 EAGAIN，被误判成断线而反复重连 */
						struct timeval tv0 = {0, 0};
						setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv0, sizeof(tv0));
						clients.push_back({cfd, true, 0, 0, 0, 0});
						fprintf(stderr, "ws client connected (%zu)\n", clients.size());
					} else close(cfd);
				} else close(cfd);
			}
		}

		for (size_t i = 0; i < clients.size();) {
			int fd = clients[i].fd;
			if (FD_ISSET(fd, &rf)) {
				unsigned char tmp[256];
				ssize_t n2 = recv(fd, tmp, sizeof(tmp), 0);
				if (n2 < 0) {
					// 超时/暂时无数据都不是断线，只有真正出错才关闭
					if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { i++; continue; }
					close(fd); clients.erase(clients.begin() + i);
					
					continue;
				}
				if (n2 == 0) {   // 对端正常关闭
					close(fd); clients.erase(clients.begin() + i);
					continue;
				}
				handleClientFrame(clients[i], tmp, (size_t)n2);
			}
			i++;
		}

		if (FD_ISSET(pfd, &rf)) {
			unsigned char pkt[2048];
			ssize_t n2 = recv(pfd, pkt, sizeof(pkt), 0);
			if (n2 > 0) {
				// loopback 有伪以太头，直接在包内定位 DMRD
				for (ssize_t i = 0; i + 55 <= n2; i++) {
					if (memcmp(pkt + i, "DMRD", 4) == 0) { handleDMRD(pkt + i, (size_t)(n2 - i)); break; }
				}
			}
		}

		double t = nowSec();
		if (t - lastFlush >= 0.1) {
			lastFlush = t;
			flushAudio();
			reapCalls();
		}
		// 心跳：远程访问时 NAT/防火墙会掐掉空闲连接，定期发 ping 保活
		if (t - lastPing >= 15) {
			lastPing = t;
			for (size_t i = clients.size(); i-- > 0;)
				if (clients[i].handshaken && !wsSend(clients[i].fd, 9, nullptr, 0)) {
					close(clients[i].fd);
					clients.erase(clients.begin() + i);
				}
		}
	}
	return 0;
}
