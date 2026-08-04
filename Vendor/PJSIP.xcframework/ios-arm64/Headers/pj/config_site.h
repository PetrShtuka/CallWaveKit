#define PJ_CONFIG_IPHONE 1
#define PJMEDIA_HAS_VIDEO 0
#define PJ_HAS_IPV6 1
/*
 * PJSIP's Apple backend uses Network.framework and Security.framework. Keep
 * this explicit: configure-iphone otherwise selects deprecated SecureTransport
 * when it happens to be present in the active SDK.
 */
#define PJ_HAS_SSL_SOCK 1
#define PJ_SSL_SOCK_IMP PJ_SSL_SOCK_IMP_APPLE
#include <pj/config_site_sample.h>
