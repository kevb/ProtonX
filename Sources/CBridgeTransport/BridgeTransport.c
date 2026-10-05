#include "BridgeTransport.h"
#include <curl/curl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdint.h>
struct px_transfer { atomic_bool cancelled; };
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
px_transfer *px_transfer_new(void) { return calloc(1, sizeof(px_transfer)); }
void px_transfer_cancel(px_transfer *t) { if (t) atomic_store(&t->cancelled, 1); }
void px_transfer_free(px_transfer *t) { free(t); }
static int progress(void *ctx, curl_off_t total, curl_off_t now, curl_off_t up_total, curl_off_t up_now) {
    (void)total; (void)now; (void)up_total; (void)up_now;
    return atomic_load(&((px_transfer *)ctx)->cancelled);
}
static size_t receive(char *ptr, size_t size, size_t count, void *ctx) {
    px_result *r = ctx;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length > 16 * 1024 * 1024 || r->length > 16 * 1024 * 1024 - length) return 0;
    unsigned char *next = realloc(r->data, r->length + length);
    if (!next && length) return 0;
    r->data = next; memcpy(r->data + r->length, ptr, length); r->length += length;
    return length;
}
typedef struct { const unsigned char *data; size_t length; size_t position; } upload;
static size_t provide(char *ptr, size_t size, size_t count, void *ctx) {
    upload *u = ctx;
    size_t capacity = size * count;
    size_t length = u->length - u->position;
    if (length > capacity) length = capacity;
    memcpy(ptr, u->data + u->position, length); u->position += length; return length;
}
px_result px_mail_request(px_transfer *transfer, const char *url, const char *username,
                         const char *password, const char *certificate, const char *command,
                         const char *sender, const char *recipient, const unsigned char *body, size_t body_length) {
    pthread_once(&once, initialize);
    px_result r = {NULL, 0, CURLE_FAILED_INIT};
    CURL *curl = curl_easy_init();
    if (!curl) return r;
    // The Swift boundary supplies a literal loopback URL. Disable proxies and redirects as defense in depth.
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "imap,imaps,smtp,smtps");
    curl_easy_setopt(curl, CURLOPT_PROXY, "");
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_USERNAME, username);
    curl_easy_setopt(curl, CURLOPT_PASSWORD, password);
    curl_easy_setopt(curl, CURLOPT_USE_SSL, (long)CURLUSESSL_ALL);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    struct curl_blob ca = {(void *)certificate, strlen(certificate), CURL_BLOB_COPY};
    curl_easy_setopt(curl, CURLOPT_CAINFO_BLOB, &ca);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 45L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, progress);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, transfer);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, receive);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &r);
    if (command && command[0]) curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, command);
    struct curl_slist *recipients = NULL;
    upload u = {body, body_length, 0};
    if (body) {
        recipients = curl_slist_append(NULL, recipient);
        curl_easy_setopt(curl, CURLOPT_MAIL_FROM, sender);
        curl_easy_setopt(curl, CURLOPT_MAIL_RCPT, recipients);
        curl_easy_setopt(curl, CURLOPT_UPLOAD, 1L);
        curl_easy_setopt(curl, CURLOPT_READFUNCTION, provide);
        curl_easy_setopt(curl, CURLOPT_READDATA, &u);
        curl_easy_setopt(curl, CURLOPT_INFILESIZE_LARGE, (curl_off_t)body_length);
    }
    r.status = (int)curl_easy_perform(curl);
    curl_slist_free_all(recipients); curl_easy_cleanup(curl); return r;
}
void px_result_free(px_result r) { if (r.data) { memset(r.data, 0, r.length); free(r.data); } }
