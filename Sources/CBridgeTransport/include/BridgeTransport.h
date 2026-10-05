#ifndef PROTONX_BRIDGE_TRANSPORT_H
#define PROTONX_BRIDGE_TRANSPORT_H
#include <stddef.h>
typedef struct px_transfer px_transfer;
typedef struct { unsigned char *data; size_t length; int status; } px_result;
px_transfer *px_transfer_new(void);
void px_transfer_cancel(px_transfer *transfer);
void px_transfer_free(px_transfer *transfer);
px_result px_mail_request(px_transfer *transfer, const char *url, const char *username,
                         const char *password, const char *certificate, const char *command,
                         const char *sender, const char *recipient, const unsigned char *body, size_t body_length);
void px_result_free(px_result result);
#endif
