/* Mail2TLS: an Mbed TLS mailstream_low driver for libetpan (see Mail2TLS.h). */
#include "Mail2TLS.h"
#include <libetpan/mailstream_low.h>
#include <mbedtls/ssl.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/error.h>
#include <mbedtls/net_sockets.h>
#include <psa/crypto.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>

/* One configuration (CA chain, RNG) shared by every connection, made on first use. */
static mbedtls_entropy_context entropy;
static mbedtls_ctr_drbg_context drbg;
static mbedtls_x509_crt cacert;
static mbedtls_ssl_config conf;
static int conf_ok;
static char conf_err[160];

/* The Pi 3's Cortex-A53 (BCM2837) has no ARMv8 crypto extensions, so AES runs in software, where ChaCha20-Poly1305 is
 * two to three times faster. Mbed TLS's own order with the ChaCha20 suites moved to the front; servers that weigh the
 * client's preference (Google's, Cloudflare's) then pick it, and the rest pick as before. */
static int *suites;

static void
prefer_chacha(void)
{
	const int *all = mbedtls_ssl_list_ciphersuites();
	size_t n = 0, k = 0, i;
	int pass;
	while (all[n] != 0)
		n++;
	suites = calloc(n + 1, sizeof(int));
	if (suites == NULL)
		return;
	for (pass = 0; pass < 2; pass++)
		for (i = 0; i < n; i++) {
			const mbedtls_ssl_ciphersuite_t *info = mbedtls_ssl_ciphersuite_from_id(all[i]);
			int chacha = info != NULL && strstr(mbedtls_ssl_ciphersuite_get_name(info), "CHACHA20") != NULL;
			if (chacha == (pass == 0))
				suites[k++] = all[i];
		}
	mbedtls_ssl_conf_ciphersuites(&conf, suites);
}

/* Sessions to resume, by server: a reconnection (IDLE every half hour, each message sent, each token fetched) then
 * skips the certificate chain and its signature checks, the dearest part of a handshake on this CPU. TLS 1.2 keeps
 * the session from the handshake; TLS 1.3 the latest ticket the server sent after it. The server still decides:
 * a session it no longer knows is a full handshake, as before. */
#define CACHE_SLOTS 16
static struct cached {
	char key[300];
	mbedtls_ssl_session session;
	int used;
	unsigned long stamp;
} cache[CACHE_SLOTS];
static unsigned long cache_clock;
static pthread_mutex_t cache_lock = PTHREAD_MUTEX_INITIALIZER;

static void
cache_key(int fd, const char *host, char *key, size_t len)
{
	struct sockaddr_storage ss;
	socklen_t sl = sizeof(ss);
	int port = 0;
	if (getpeername(fd, (struct sockaddr *)&ss, &sl) == 0)
		port = ntohs(ss.ss_family == AF_INET6 ? ((struct sockaddr_in6 *)&ss)->sin6_port : ((struct sockaddr_in *)&ss)->sin_port);
	snprintf(key, len, "%s:%d", host, port);
}

/* the connection's session, if it has one to give, kept for its server (replacing what was there) */
static void
cache_store(const char *key, mbedtls_ssl_context *ssl)
{
	mbedtls_ssl_session s;
	int i, slot = -1;
	mbedtls_ssl_session_init(&s);
	if (mbedtls_ssl_get_session(ssl, &s) != 0) {
		mbedtls_ssl_session_free(&s);
		return;
	}
	pthread_mutex_lock(&cache_lock);
	for (i = 0; i < CACHE_SLOTS; i++)
		if (cache[i].used && strcmp(cache[i].key, key) == 0)
			slot = i;
	for (i = 0; slot < 0 && i < CACHE_SLOTS; i++)
		if (!cache[i].used)
			slot = i;
	if (slot < 0) {	/* full: the oldest goes */
		slot = 0;
		for (i = 1; i < CACHE_SLOTS; i++)
			if (cache[i].stamp < cache[slot].stamp)
				slot = i;
	}
	if (cache[slot].used)
		mbedtls_ssl_session_free(&cache[slot].session);
	snprintf(cache[slot].key, sizeof(cache[slot].key), "%s", key);
	cache[slot].session = s;	/* moved, not copied: s is not freed here */
	cache[slot].used = 1;
	cache[slot].stamp = ++cache_clock;
	pthread_mutex_unlock(&cache_lock);
}

/* offers the server's kept session, if any; 1 if one was offered */
static int
cache_offer(const char *key, mbedtls_ssl_context *ssl)
{
	int i, offered = 0;
	pthread_mutex_lock(&cache_lock);
	for (i = 0; i < CACHE_SLOTS; i++)
		if (cache[i].used && strcmp(cache[i].key, key) == 0) {
			offered = mbedtls_ssl_set_session(ssl, &cache[i].session) == 0;
			cache[i].stamp = ++cache_clock;
		}
	pthread_mutex_unlock(&cache_lock);
	return offered;
}
static pthread_once_t conf_once = PTHREAD_ONCE_INIT;

static void
setup_conf(void)
{
	int r;
	/* TLS 1.3 in Mbed TLS 3.6 runs on PSA crypto */
	if (psa_crypto_init() != PSA_SUCCESS) {
		snprintf(conf_err, sizeof(conf_err), "TLS: psa_crypto_init failed");
		return;
	}
	mbedtls_entropy_init(&entropy);
	mbedtls_ctr_drbg_init(&drbg);
	mbedtls_x509_crt_init(&cacert);
	mbedtls_ssl_config_init(&conf);
	if ((r = mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy, (const unsigned char *)"mail2", 5)) != 0) {
		snprintf(conf_err, sizeof(conf_err), "TLS: cannot seed the RNG (-0x%04x)", -r);
		return;
	}
	if ((r = mbedtls_x509_crt_parse_file(&cacert, MAIL2_CA_BUNDLE)) < 0) {
		snprintf(conf_err, sizeof(conf_err), "TLS: cannot read %s (-0x%04x)", MAIL2_CA_BUNDLE, -r);
		return;
	}
	if ((r = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM,
	    MBEDTLS_SSL_PRESET_DEFAULT)) != 0) {
		snprintf(conf_err, sizeof(conf_err), "TLS: config failed (-0x%04x)", -r);
		return;
	}
	mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_REQUIRED);
	mbedtls_ssl_conf_ca_chain(&conf, &cacert, NULL);
	mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);
	prefer_chacha();
	/* TLS 1.3 tickets are ignored unless asked for; then a read returns ..._RECEIVED_NEW_SESSION_TICKET for each */
	mbedtls_ssl_conf_tls13_enable_signal_new_session_tickets(&conf, MBEDTLS_SSL_TLS1_3_SIGNAL_NEW_SESSION_TICKETS_ENABLED);
	conf_ok = 1;
}

struct tls_data {
	int fd;
	int timeout_ms;
	mbedtls_ssl_context ssl;
	char key[300];		/* host:port, for the session cache */
	int resumed;		/* the handshake resumed a kept session (no certificate came) */
};

/* A blocking call interrupted by a signal is retried. libetpan's own socket driver does not retry its select() and
 * fails the read instead; MAIL2_DEBUG=1 counts the interruptions. */
static void
note_eintr(void)
{
	static int n;
	const char *d = getenv("MAIL2_DEBUG");
	if (d && *d == '1')
		fprintf(stderr, "mail2: poll interrupted by a signal (%d), retried\n", ++n);
}

static void
debug_failure(const char *what, int e)
{
	const char *d = getenv("MAIL2_DEBUG");
	if (d && *d == '1')
		fprintf(stderr, "mail2: socket %s failed: %s (thread %p)\n", what, e ? strerror(e) : "-", (void *)pthread_self());
}

/* BIO callbacks on the blocking socket; reads wait at most timeout_ms */
static int
bio_send(void *ctx, const unsigned char *buf, size_t len)
{
	struct tls_data *t = ctx;
	ssize_t n;
	do
		n = write(t->fd, buf, len);
	while (n < 0 && errno == EINTR);
	return n < 0 ? MBEDTLS_ERR_NET_SEND_FAILED : (int)n;
}

static int
bio_recv(void *ctx, unsigned char *buf, size_t len)
{
	struct tls_data *t = ctx;
	struct pollfd p = { t->fd, POLLIN, 0 };
	ssize_t n;
	int r;
	while ((r = poll(&p, 1, t->timeout_ms)) < 0 && errno == EINTR)
		note_eintr();
	if (r == 0)
		return MBEDTLS_ERR_SSL_TIMEOUT;
	if (r < 0) {
		debug_failure("poll", errno);
		return MBEDTLS_ERR_NET_RECV_FAILED;
	}
	while ((n = read(t->fd, buf, len)) < 0 && errno == EINTR)
		note_eintr();
	if (n <= 0)
		if (n != 0)	/* the end of the stream is how a server says goodbye (HTTP's Connection: close): not news */
			debug_failure("read", errno);
	return n < 0 ? MBEDTLS_ERR_NET_RECV_FAILED : (int)n;
}

static ssize_t
tls_read(mailstream_low *s, void *buf, size_t count)
{
	struct tls_data *t = s->data;
	for (;;) {
		int r = mbedtls_ssl_read(&t->ssl, buf, count);
		if (r >= 0)
			return r;
		/* TLS 1.3 servers send session tickets after the handshake: not data; kept, and read on */
		if (r == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) {
			cache_store(t->key, &t->ssl);
			continue;
		}
		if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE)
			continue;
		if (r == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)
			return 0;
		return -1;
	}
}

static ssize_t
tls_write(mailstream_low *s, const void *buf, size_t count)
{
	struct tls_data *t = s->data;
	size_t done = 0;
	while (done < count) {
		int r = mbedtls_ssl_write(&t->ssl, (const unsigned char *)buf + done, count - done);
		if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE)
			continue;
		if (r < 0)
			return done > 0 ? (ssize_t)done : -1;
		done += r;
	}
	return done;
}

static int
tls_close(mailstream_low *s)
{
	struct tls_data *t = s->data;
	if (t->fd >= 0) {
		mbedtls_ssl_close_notify(&t->ssl);
		close(t->fd);
		t->fd = -1;
	}
	return 0;
}

static int
tls_get_fd(mailstream_low *s)
{
	return ((struct tls_data *)s->data)->fd;
}

static void
tls_free(mailstream_low *s)
{
	struct tls_data *t = s->data;
	mbedtls_ssl_free(&t->ssl);
	free(t);
	free(s);
}

static mailstream_low_driver tls_driver = {
	tls_read, tls_write, tls_close, tls_get_fd, tls_free,
	NULL,	/* cancel */
	NULL,	/* get_cancel */
	NULL,	/* get_certificate_chain */
	NULL,	/* setup_idle */
	NULL,	/* unsetup_idle */
	NULL,	/* interrupt_idle */
};

/* ---- the same socket without TLS (plain connections, and before STARTTLS) ---- */

static ssize_t
plain_read(mailstream_low *s, void *buf, size_t count)
{
	struct tls_data *t = s->data;
	int r = bio_recv(t, buf, count);
	return r < 0 ? -1 : r;
}

static ssize_t
plain_write(mailstream_low *s, const void *buf, size_t count)
{
	struct tls_data *t = s->data;
	size_t done = 0;
	while (done < count) {
		int r = bio_send(t, (const unsigned char *)buf + done, count - done);
		if (r < 0)
			return done > 0 ? (ssize_t)done : -1;
		done += r;
	}
	return done;
}

static int
plain_close(mailstream_low *s)
{
	struct tls_data *t = s->data;
	if (t->fd >= 0) {
		close(t->fd);
		t->fd = -1;
	}
	return 0;
}

/* does not close the socket: STARTTLS hands it on to the TLS driver */
static void
plain_free(mailstream_low *s)
{
	free(s->data);
	free(s);
}

static mailstream_low_driver plain_driver = {
	plain_read, plain_write, plain_close, tls_get_fd, plain_free,
	NULL, NULL, NULL, NULL, NULL, NULL,
};

static const char *
verify_reason(uint32_t flags)
{
	/* the most basic problem first: an untrusted certificate is usually also for the wrong name */
	if (flags & MBEDTLS_X509_BADCERT_NOT_TRUSTED) return "the certificate is not signed by a trusted authority";
	if (flags & MBEDTLS_X509_BADCERT_EXPIRED) return "the certificate has expired";
	if (flags & MBEDTLS_X509_BADCERT_FUTURE) return "the certificate is not valid yet (is the clock right?)";
	if (flags & MBEDTLS_X509_BADCERT_CN_MISMATCH) return "the certificate is for another host";
	return "the certificate could not be verified";
}

/* TLS over a connected socket; the socket is the driver's on success, still the caller's on failure */
static mailstream_low *
tls_open(int fd, const char *host, int timeout_s, char *err, size_t errlen)
{
	struct tls_data *t;
	mailstream_low *low;
	int r;

	pthread_once(&conf_once, setup_conf);
	if (!conf_ok) {
		snprintf(err, errlen, "%s", conf_err);
		return NULL;
	}
	t = calloc(1, sizeof(*t));
	if (t == NULL)
		return NULL;
	t->fd = fd;
	t->timeout_ms = (timeout_s > 0 ? timeout_s : 60) * 1000;
	mbedtls_ssl_init(&t->ssl);
	if ((r = mbedtls_ssl_setup(&t->ssl, &conf)) != 0 || (r = mbedtls_ssl_set_hostname(&t->ssl, host)) != 0) {
		snprintf(err, errlen, "TLS setup failed (-0x%04x)", -r);
		goto fail;
	}
	mbedtls_ssl_set_bio(&t->ssl, t, bio_send, bio_recv, NULL);
	cache_key(fd, host, t->key, sizeof(t->key));
	int offered = cache_offer(t->key, &t->ssl), saw_cert = 0;
	/* step by step, to see whether the server sent its certificate (a full handshake) or resumed */
	while (!mbedtls_ssl_is_handshake_over(&t->ssl)) {
		if (t->ssl.MBEDTLS_PRIVATE(state) == MBEDTLS_SSL_SERVER_CERTIFICATE)
			saw_cert = 1;
		r = mbedtls_ssl_handshake_step(&t->ssl);
		if (r == 0 || r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE)
			continue;
		if (r == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) {
			cache_store(t->key, &t->ssl);
			continue;
		}
		if (r == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED)
			snprintf(err, errlen, "Cannot verify %s: %s.", host, verify_reason(mbedtls_ssl_get_verify_result(&t->ssl)));
		else if (r == MBEDTLS_ERR_SSL_TIMEOUT)
			snprintf(err, errlen, "%s did not answer the TLS handshake.", host);
		else {
			char e[100];
			mbedtls_strerror(r, e, sizeof(e));
			snprintf(err, errlen, "TLS handshake with %s failed: %s", host, e);
		}
		goto fail;
	}
	t->resumed = offered && !saw_cert;
	if (mbedtls_ssl_get_version_number(&t->ssl) == MBEDTLS_SSL_VERSION_TLS1_2)
		cache_store(t->key, &t->ssl);	/* 1.3's come later, as tickets */
	{
		const char *d = getenv("MAIL2_DEBUG");
		if (d && *d == '1')
			fprintf(stderr, "mail2: TLS with %s: %s, %s%s\n", t->key, mbedtls_ssl_get_version(&t->ssl),
			    mbedtls_ssl_get_ciphersuite(&t->ssl), t->resumed ? ", resumed" : "");
	}
	low = mailstream_low_new(t, &tls_driver);
	if (low != NULL)
		return low;
	snprintf(err, errlen, "out of memory");
fail:
	mbedtls_ssl_free(&t->ssl);
	free(t);
	return NULL;
}

/* a TCP connection with a connect timeout (non-blocking connect + poll); the socket is left blocking */
static int
tcp_connect(const char *host, int port, int timeout_s, char *err, size_t errlen)
{
	struct addrinfo hints, *res, *ai;
	char portstr[16];
	int fd = -1, r, lasterr = 0;

	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	snprintf(portstr, sizeof(portstr), "%d", port);
	if ((r = getaddrinfo(host, portstr, &hints, &res)) != 0) {
		snprintf(err, errlen, "Cannot find the server %s (%s).", host, gai_strerror(r));
		return -1;
	}
	for (ai = res; ai != NULL; ai = ai->ai_next) {
		fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
		if (fd < 0)
			continue;
		fcntl(fd, F_SETFD, FD_CLOEXEC);
		{
			int one = 1;
			setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
			setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
		}
		fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
		r = connect(fd, ai->ai_addr, ai->ai_addrlen);
		if (r < 0 && errno == EINPROGRESS) {
			struct pollfd p = { fd, POLLOUT, 0 };
			socklen_t sl = sizeof(lasterr);
			r = poll(&p, 1, timeout_s * 1000);
			if (r == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &lasterr, &sl) == 0 && lasterr == 0)
				r = 0;
			else {
				if (r == 0)
					lasterr = ETIMEDOUT;
				r = -1;
			}
		} else if (r < 0)
			lasterr = errno;
		if (r == 0) {
			fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
			break;
		}
		close(fd);
		fd = -1;
	}
	freeaddrinfo(res);
	if (fd < 0)
		snprintf(err, errlen, "Cannot connect to %s port %d: %s.", host, port, strerror(lasterr ? lasterr : ECONNREFUSED));
	return fd;
}

mailstream *
mail2_connect(const char *host, int port, int tls, int timeout_s, char *err, size_t errlen)
{
	mailstream *s;
	int fd;

	err[0] = '\0';
	fd = tcp_connect(host, port, timeout_s, err, errlen);
	if (fd < 0)
		return NULL;
	if (!tls) {
		struct tls_data *t = calloc(1, sizeof(*t));
		mailstream_low *low = t ? mailstream_low_new(t, &plain_driver) : NULL;
		s = low ? mailstream_new(low, 8192) : NULL;
		if (s == NULL) {
			close(fd);
			snprintf(err, errlen, "out of memory");
			return NULL;
		}
		t->fd = fd;
		t->timeout_ms = (timeout_s > 0 ? timeout_s : 60) * 1000;
		mailstream_low_set_timeout(low, timeout_s);
		return s;
	}
	mailstream_low *low = tls_open(fd, host, timeout_s, err, errlen);
	if (low == NULL) {
		close(fd);
		return NULL;
	}
	mailstream_low_set_timeout(low, timeout_s);
	s = mailstream_new(low, 8192);
	if (s == NULL) {
		mailstream_low_close(low);
		mailstream_low_free(low);
		snprintf(err, errlen, "out of memory");
	}
	return s;
}

int
mail2_starttls(mailstream *s, const char *host, char *err, size_t errlen)
{
	mailstream_low *plain = mailstream_get_low(s), *low;
	int fd = mailstream_low_get_fd(plain);
	if (fd < 0) {
		snprintf(err, errlen, "STARTTLS: no socket");
		return -1;
	}
	low = tls_open(fd, host, (int)plain->timeout, err, errlen);
	if (low == NULL)
		return -1;
	mailstream_low_set_timeout(low, plain->timeout);
	/* the plain driver's free does not close the descriptor, which TLS now owns */
	mailstream_low_free(plain);
	mailstream_set_low(s, low);
	return 0;
}

int
mail2_tls_info(mailstream *s, const char **suite, int *resumed)
{
	mailstream_low *low = mailstream_get_low(s);
	if (low == NULL || low->driver != &tls_driver)
		return -1;
	struct tls_data *t = low->data;
	if (suite)
		*suite = mbedtls_ssl_get_ciphersuite(&t->ssl);
	if (resumed)
		*resumed = t->resumed;
	return 0;
}
