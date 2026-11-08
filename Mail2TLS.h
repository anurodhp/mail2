/* Mail2TLS: Mbed TLS under libetpan. libetpan's own TLS is OpenSSL or GnuTLS, which this system has neither of; it
 * takes any transport as a mailstream_low driver, so this is one on Mbed TLS (iokit's build_mbedtls.sh, the library
 * curl uses here), verifying the server against /etc/ssl/cert.pem and the host name.
 *
 * mail2_connect() opens a TCP connection and returns a mailstream: TLS from the start (IMAPS 993, SMTPS 465) or
 * plain, to be upgraded with mail2_starttls() after the protocol's STARTTLS command (IMAP 143, submission 587). */
#ifndef MAIL2_TLS_H
#define MAIL2_TLS_H
#include <libetpan/mailstream.h>

#define MAIL2_CA_BUNDLE "/etc/ssl/cert.pem"

/* NULL on failure, with a message in err (NUL-terminated, at most errlen bytes) */
mailstream *mail2_connect(const char *host, int port, int tls, int timeout_s, char *err, size_t errlen);
/* replaces the stream's plain transport with TLS over the same socket; 0 on success */
int mail2_starttls(mailstream *s, const char *host, char *err, size_t errlen);

#endif
