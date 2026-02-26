#include <ctype.h>
#include <curl/curl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ================================================================== */
/* types                                                              */
/* ================================================================== */

typedef struct {
    char *b;
    size_t n, cap;
} Buf;
typedef struct {
    const char *s;
    size_t i;
} Cur;
typedef struct {
    char *data;
    size_t len;
} ResponseBuf;
typedef struct {
    char **items;
    size_t count;
} ItemList;

/* ================================================================== */
/* buffer                                                             */
/* ================================================================== */

static void b_write(Buf *b, const char *s, size_t n) {
    if (b->n + n + 1 > b->cap) {
        b->cap = (b->cap + n + 1) * 2;
        b->b = realloc(b->b, b->cap);
    }
    memcpy(b->b + b->n, s, n);
    b->n += n;
    b->b[b->n] = '\0';
}
static void b_str(Buf *b, const char *s) {
    b_write(b, s, strlen(s));
}
static void b_chr(Buf *b, char c) {
    b_write(b, &c, 1);
}
static void b_fmt(Buf *b, const char *fmt, ...) {
    char tmp[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    b_str(b, tmp);
}

/* ================================================================== */
/* cursor / json primitives                                           */
/* ================================================================== */

static void ws(Cur *c) {
    while (isspace((unsigned char)c->s[c->i]))
        c->i++;
}

static char *read_str(Cur *c) {
    ws(c);
    if (c->s[c->i] != '"')
        return NULL;
    c->i++;
    Buf tmp = {0};
    while (c->s[c->i] && c->s[c->i] != '"') {
        if (c->s[c->i] == '\\') {
            b_chr(&tmp, c->s[c->i++]);
            if (c->s[c->i])
                b_chr(&tmp, c->s[c->i++]);
        } else {
            b_chr(&tmp, c->s[c->i++]);
        }
    }
    if (c->s[c->i] == '"')
        c->i++;
    if (!tmp.b)
        tmp.b = strdup("");
    return tmp.b;
}

/* copies the current JSON value verbatim (with its delimiters) into out */
static void copy_raw_value(Cur *c, Buf *out) {
    ws(c);
    if (c->s[c->i] == '"') {
        b_chr(out, '"');
        c->i++;
        while (c->s[c->i] && c->s[c->i] != '"') {
            if (c->s[c->i] == '\\') {
                b_chr(out, '\\');
                c->i++;
                if (c->s[c->i])
                    b_chr(out, c->s[c->i++]);
            } else {
                b_chr(out, c->s[c->i++]);
            }
        }
        if (c->s[c->i] == '"') {
            b_chr(out, '"');
            c->i++;
        }
        return;
    }
    if (c->s[c->i] == '{' || c->s[c->i] == '[') {
        int depth = 0, in_str = 0;
        while (c->s[c->i]) {
            char ch = c->s[c->i];
            b_chr(out, ch);
            if (in_str) {
                if (ch == '\\') {
                    c->i++;
                    if (c->s[c->i])
                        b_chr(out, c->s[c->i++]);
                    continue;
                }
                if (ch == '"')
                    in_str = 0;
            } else {
                if (ch == '"')
                    in_str = 1;
                else if (ch == '{' || ch == '[')
                    depth++;
                else if (ch == '}' || ch == ']') {
                    depth--;
                    if (!depth) {
                        c->i++;
                        return;
                    }
                }
            }
            c->i++;
        }
        return;
    }
    /* scalar */
    while (c->s[c->i] && !isspace((unsigned char)c->s[c->i]) &&
           c->s[c->i] != ',' && c->s[c->i] != '}' && c->s[c->i] != ']')
        b_chr(out, c->s[c->i++]);
}

static void skip_value(Cur *c) {
    Buf d = {0};
    copy_raw_value(c, &d);
    free(d.b);
}

/* ================================================================== */
/* json utilities                                                       */
/* ================================================================== */

/* returns raw JSON value for key in a JSON object, caller frees */
static char *json_get_raw(const char *json, const char *key) {
    if (!json)
        return NULL;
    Cur c = {json, 0};
    ws(&c);
    if (c.s[c.i] != '{')
        return NULL;
    c.i++;
    while (1) {
        ws(&c);
        if (!c.s[c.i] || c.s[c.i] == '}')
            break;
        char *k = read_str(&c);
        if (!k)
            break;
        ws(&c);
        if (c.s[c.i] == ':')
            c.i++;
        if (strcmp(k, key) == 0) {
            free(k);
            Buf tmp = {0};
            copy_raw_value(&c, &tmp);
            return tmp.b ? tmp.b : strdup("");
        }
        free(k);
        skip_value(&c);
        ws(&c);
        if (c.s[c.i] == ',')
            c.i++;
    }
    return NULL;
}

/* returns unquoted string value for key, caller frees */
static char *json_get_string(const char *json, const char *key) {
    char *raw = json_get_raw(json, key);
    if (!raw)
        return NULL;
    Cur c = {raw, 0};
    ws(&c);
    char *val = (c.s[c.i] == '"') ? read_str(&c) : strdup(raw);
    free(raw);
    return val;
}

/* ================================================================== */
/* dynamo unmarshal                                                     */
/* ================================================================== */

static int is_dynamo_type(const char *k) {
    static const char *types[] = {"S",  "N",  "B", "BOOL", "NULL", "SS",
                                  "NS", "BS", "M", "L",    NULL};
    for (int i = 0; types[i]; i++)
        if (strcmp(k, types[i]) == 0)
            return 1;
    return 0;
}

static void unmarshal_value(Cur *c, Buf *out);

static void unmarshal_array(Cur *c, Buf *out) {
    ws(c);
    c->i++;
    b_chr(out, '[');
    ws(c);
    if (c->s[c->i] == ']') {
        c->i++;
        b_chr(out, ']');
        return;
    }
    int first = 1;
    while (c->s[c->i] && c->s[c->i] != ']') {
        if (!first)
            b_chr(out, ',');
        first = 0;
        unmarshal_value(c, out);
        ws(c);
        if (c->s[c->i] == ',')
            c->i++;
        ws(c);
    }
    if (c->s[c->i] == ']')
        c->i++;
    b_chr(out, ']');
}

static void unmarshal_number_set(Cur *c, Buf *out) {
    ws(c);
    c->i++;
    b_chr(out, '[');
    ws(c);
    if (c->s[c->i] == ']') {
        c->i++;
        b_chr(out, ']');
        return;
    }
    int first = 1;
    while (c->s[c->i] && c->s[c->i] != ']') {
        if (!first)
            b_chr(out, ',');
        first = 0;
        char *s = read_str(c);
        b_str(out, s);
        free(s);
        ws(c);
        if (c->s[c->i] == ',')
            c->i++;
        ws(c);
    }
    if (c->s[c->i] == ']')
        c->i++;
    b_chr(out, ']');
}

static void copy_scalar(Cur *c, Buf *out) {
    ws(c);
    while (c->s[c->i] && !isspace((unsigned char)c->s[c->i]) &&
           c->s[c->i] != ',' && c->s[c->i] != '}' && c->s[c->i] != ']')
        b_chr(out, c->s[c->i++]);
}

static void unmarshal_object(Cur *c, Buf *out) {
    ws(c);
    c->i++;
    b_chr(out, '{');
    ws(c);
    if (c->s[c->i] == '}') {
        c->i++;
        b_chr(out, '}');
        return;
    }
    int first = 1;
    while (c->s[c->i] && c->s[c->i] != '}') {
        if (!first)
            b_chr(out, ',');
        first = 0;
        char *key = read_str(c);
        b_chr(out, '"');
        b_str(out, key);
        b_chr(out, '"');
        free(key);
        ws(c);
        if (c->s[c->i] == ':')
            c->i++;
        b_chr(out, ':');
        unmarshal_value(c, out);
        ws(c);
        if (c->s[c->i] == ',')
            c->i++;
        ws(c);
    }
    if (c->s[c->i] == '}')
        c->i++;
    b_chr(out, '}');
}

static void unmarshal_value(Cur *c, Buf *out) {
    ws(c);
    if (c->s[c->i] == '[') {
        unmarshal_array(c, out);
        return;
    }
    if (c->s[c->i] == '"') {
        char *s = read_str(c);
        b_chr(out, '"');
        b_str(out, s);
        b_chr(out, '"');
        free(s);
        return;
    }
    if (c->s[c->i] != '{') {
        copy_scalar(c, out);
        return;
    }

    size_t saved = c->i;
    c->i++;
    ws(c);
    if (c->s[c->i] == '}') {
        c->i++;
        b_str(out, "{}");
        return;
    }

    char *first_key = read_str(c);
    if (!first_key || !is_dynamo_type(first_key)) {
        free(first_key);
        c->i = saved;
        unmarshal_object(c, out);
        return;
    }

    ws(c);
    if (c->s[c->i] == ':')
        c->i++;

    if (strcmp(first_key, "S") == 0) {
        char *s = read_str(c);
        b_chr(out, '"');
        b_str(out, s);
        b_chr(out, '"');
        free(s);
    } else if (strcmp(first_key, "N") == 0) {
        char *s = read_str(c);
        b_str(out, s);
        free(s);
    } else if (strcmp(first_key, "BOOL") == 0) {
        copy_scalar(c, out);
    } else if (strcmp(first_key, "NULL") == 0) {
        skip_value(c);
        b_str(out, "null");
    } else if (strcmp(first_key, "B") == 0) {
        char *s = read_str(c);
        b_chr(out, '"');
        b_str(out, s);
        b_chr(out, '"');
        free(s);
    } else if (strcmp(first_key, "SS") == 0 || strcmp(first_key, "BS") == 0) {
        unmarshal_array(c, out);
    } else if (strcmp(first_key, "NS") == 0) {
        unmarshal_number_set(c, out);
    } else if (strcmp(first_key, "M") == 0) {
        unmarshal_object(c, out);
    } else if (strcmp(first_key, "L") == 0) {
        unmarshal_array(c, out);
    }

    free(first_key);
    ws(c);
    if (c->s[c->i] == '}')
        c->i++;
}

char *dynamo_unmarshal(const char *json) {
    Cur c = {json, 0};
    Buf out = {0};
    unmarshal_value(&c, &out);
    return out.b ? out.b : strdup("");
}

/* ================================================================== */
/* marshal (plain JSON → DynamoDB wire format)                         */
/* ================================================================== */

static void marshal_value(Cur *c, Buf *out);

static void marshal_array_contents(Cur *c, Buf *out) {
    ws(c);
    c->i++; /* skip '[' */
    b_chr(out, '[');
    ws(c);
    int first = 1;
    while (c->s[c->i] && c->s[c->i] != ']') {
        if (!first) b_chr(out, ',');
        first = 0;
        marshal_value(c, out);
        ws(c);
        if (c->s[c->i] == ',') c->i++;
        ws(c);
    }
    if (c->s[c->i] == ']') c->i++;
    b_chr(out, ']');
}

static void marshal_object_contents(Cur *c, Buf *out) {
    ws(c);
    c->i++; /* skip '{' */
    b_chr(out, '{');
    ws(c);
    int first = 1;
    while (c->s[c->i] && c->s[c->i] != '}') {
        if (!first) b_chr(out, ',');
        first = 0;
        Buf key_buf = {0};
        copy_raw_value(c, &key_buf);
        b_str(out, key_buf.b);
        free(key_buf.b);
        ws(c);
        if (c->s[c->i] == ':') c->i++;
        b_chr(out, ':');
        marshal_value(c, out);
        ws(c);
        if (c->s[c->i] == ',') c->i++;
        ws(c);
    }
    if (c->s[c->i] == '}') c->i++;
    b_chr(out, '}');
}

static void marshal_value(Cur *c, Buf *out) {
    ws(c);
    char ch = c->s[c->i];

    if (ch == '"') {
        Buf raw = {0};
        copy_raw_value(c, &raw);
        b_str(out, "{\"S\":");
        b_str(out, raw.b);
        b_chr(out, '}');
        free(raw.b);
        return;
    }
    if (ch == '[') {
        b_str(out, "{\"L\":");
        marshal_array_contents(c, out);
        b_chr(out, '}');
        return;
    }
    if (ch == '{') {
        b_str(out, "{\"M\":");
        marshal_object_contents(c, out);
        b_chr(out, '}');
        return;
    }
    /* scalar: number, true, false, null */
    Buf scalar = {0};
    copy_scalar(c, &scalar);
    if (scalar.b) {
        if (strcmp(scalar.b, "null") == 0) {
            b_str(out, "{\"NULL\":true}");
        } else if (strcmp(scalar.b, "true") == 0) {
            b_str(out, "{\"BOOL\":true}");
        } else if (strcmp(scalar.b, "false") == 0) {
            b_str(out, "{\"BOOL\":false}");
        } else {
            b_str(out, "{\"N\":\"");
            b_str(out, scalar.b);
            b_str(out, "\"}");
        }
        free(scalar.b);
    }
}

/* converts a plain JSON object to DynamoDB wire format; caller frees */
static char *dynamo_marshal(const char *json) {
    Cur c = {json, 0};
    Buf out = {0};
    ws(&c);
    if (c.s[c.i] != '{') return NULL;
    marshal_object_contents(&c, &out);
    return out.b ? out.b : strdup("{}");
}

/* ================================================================== */
/* curl layer                                                           */
/* ================================================================== */

static size_t write_cb(void *ptr, size_t size, size_t nmemb, void *userdata) {
    size_t real = size * nmemb;
    ResponseBuf *buf = userdata;
    char *tmp = realloc(buf->data, buf->len + real + 1);
    if (!tmp)
        return 0;
    buf->data = tmp;
    memcpy(buf->data + buf->len, ptr, real);
    buf->len += real;
    buf->data[buf->len] = '\0';
    return real;
}

/*
 * Thread-local curl handles — one per service endpoint.
 * curl_easy_reset() clears options but preserves the connection cache,
 * so TCP/TLS connections are reused across calls on the same thread.
 */
static __thread CURL *tl_dynamo_curl = NULL;
static __thread CURL *tl_lambda_curl = NULL;
static __thread CURL *tl_http_curl   = NULL;

static CURL *get_curl(CURL **handle) {
    if (!*handle) {
        *handle = curl_easy_init();
    } else {
        curl_easy_reset(*handle);
    }
    if (*handle) {
        curl_easy_setopt(*handle, CURLOPT_TCP_KEEPALIVE, 1L);
        curl_easy_setopt(*handle, CURLOPT_TCP_KEEPIDLE, 30L);
        curl_easy_setopt(*handle, CURLOPT_TCP_KEEPINTVL, 10L);
    }
    return *handle;
}

/* makes a DynamoDB API call; returns raw response body, caller frees */
static char *dynamo_request(const char *target, const char *body) {
    const char *key_id = getenv("AWS_ACCESS_KEY_ID");
    const char *secret = getenv("AWS_SECRET_ACCESS_KEY");
    const char *region = getenv("AWS_REGION");

    if (!key_id || !secret || !region) {
        fprintf(stderr, "AWS credentials/region missing\n");
        return NULL;
    }

    char url[128], userpwd[256], sigv4[128], target_hdr[128];
    snprintf(url, sizeof(url), "https://dynamodb.%s.amazonaws.com/", region);
    snprintf(userpwd, sizeof(userpwd), "%s:%s", key_id, secret);
    snprintf(sigv4, sizeof(sigv4), "aws:amz:%s:dynamodb", region);
    snprintf(target_hdr, sizeof(target_hdr), "X-Amz-Target: %s", target);

    CURL *curl = get_curl(&tl_dynamo_curl);
    if (!curl)
        return NULL;

    struct curl_slist *headers = NULL;
    headers =
        curl_slist_append(headers, "Content-Type: application/x-amz-json-1.0");
    headers = curl_slist_append(headers, target_hdr);

    ResponseBuf resp = {0};

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_AWS_SIGV4, sigv4);
    curl_easy_setopt(curl, CURLOPT_USERPWD, userpwd);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &resp);

    CURLcode res = curl_easy_perform(curl);
    curl_slist_free_all(headers);

    if (res != CURLE_OK) {
        fprintf(stderr, "curl error: %s\n", curl_easy_strerror(res));
        free(resp.data);
        return NULL;
    }

    return resp.data;
}

/* ================================================================== */
/* query response parsing                                               */
/* ================================================================== */

void item_list_free(ItemList *l) {
    for (size_t i = 0; i < l->count; i++)
        free(l->items[i]);
    free(l->items);
    l->items = NULL;
    l->count = 0;
}

/*
 * Parses the Items array from a Query response.
 * Each item is unmarshalled before storage.
 * *out_last_key is set to a heap-allocated raw JSON string of LastEvaluatedKey,
 * or NULL if there are no more pages. Caller frees.
 */
static ItemList parse_query_items(const char *response, char **out_last_key) {
    ItemList list = {0};
    if (out_last_key)
        *out_last_key = NULL;

    char *items_raw = json_get_raw(response, "Items");
    if (!items_raw)
        return list;

    Cur c = {items_raw, 0};
    ws(&c);
    if (c.s[c.i] != '[') {
        free(items_raw);
        return list;
    }
    c.i++;
    ws(&c);

    while (c.s[c.i] && c.s[c.i] != ']') {
        Buf raw = {0};
        copy_raw_value(&c, &raw);

        list.items = realloc(list.items, (list.count + 1) * sizeof(char *));
        list.items[list.count++] = dynamo_unmarshal(raw.b);
        free(raw.b);

        ws(&c);
        if (c.s[c.i] == ',')
            c.i++;
        ws(&c);
    }

    free(items_raw);

    if (out_last_key)
        *out_last_key = json_get_raw(response, "LastEvaluatedKey");

    return list;
}

/* ================================================================== */
/* helpers                                                              */
/* ================================================================== */

static void str_upper(const char *src, char *dst) {
    while (*src)
        *dst++ = toupper((unsigned char)*src++);
    *dst = '\0';
}

/* replace with your actual stemming logic */
static const char *string_stem(const char *s) {
    return s;
}

/*
 * Returns 0 if owner check passes, -1 if forbidden.
 * item_json must be already unmarshalled (plain JSON).
 */
int check_owner(const char *item_json, const char *owner) {
    if (!owner)
        return 0;

    char *item_owner = json_get_string(item_json, "OWNER");
    if (!item_owner)
        return 0; /* no OWNER field — pass */

    if (strcmp(item_owner, owner) == 0) {
        free(item_owner);
        return 0;
    }

    /* check sharedWith array */
    char *shared_raw = json_get_raw(item_json, "sharedWith");
    if (shared_raw) {
        Cur c = {shared_raw, 0};
        ws(&c);
        if (c.s[c.i] == '[') {
            c.i++;
            while (c.s[c.i] && c.s[c.i] != ']') {
                ws(&c);
                char *entry = read_str(&c);
                if (entry && strcmp(entry, owner) == 0) {
                    free(entry);
                    free(shared_raw);
                    free(item_owner);
                    return 0;
                }
                free(entry);
                ws(&c);
                if (c.s[c.i] == ',')
                    c.i++;
            }
        }
        free(shared_raw);
    }

    free(item_owner);
    return -1;
}

/* appends ExclusiveStartKey to an open JSON body (no closing }) then closes it
 */
static void append_exclusive_start_key(Buf *body, const char *last_key) {
    if (last_key) {
        b_str(body, ",\"ExclusiveStartKey\":");
        b_str(body, last_key);
    }
    b_chr(body, '}');
}

/* ================================================================== */
/* dynamo operations                                                    */
/* ================================================================== */

/*
 * Returns heap-allocated unmarshalled JSON of the Item, or NULL if not found.
 * Caller frees.
 */
char *get_item_pk_sk(const char *prefix, const char *pk, const char *sk) {
    const char *table = getenv("DYNAMO_TABLE_NAME");
    if (!table) {
        fprintf(stderr, "DYNAMO_TABLE_NAME not defined\n");
        return NULL;
    }

    char upper[64];
    str_upper(prefix, upper);
    char pk_val[512], sk_val[512];
    snprintf(pk_val, sizeof(pk_val), "%s#%s", upper, string_stem(pk));
    snprintf(sk_val, sizeof(sk_val), "%s#%s", upper, string_stem(sk));

    Buf body = {0};
    b_fmt(&body,
          "{\"TableName\":\"%s\","
          "\"Key\":{\"pk\":{\"S\":\"%s\"},\"sk\":{\"S\":\"%s\"}}}",
          table, pk_val, sk_val);

    char *resp = dynamo_request("DynamoDB_20120810.GetItem", body.b);
    free(body.b);
    if (!resp)
        return NULL;

    char *item_raw = json_get_raw(resp, "Item");
    free(resp);
    if (!item_raw)
        return NULL;

    char *result = dynamo_unmarshal(item_raw);
    free(item_raw);
    return result;
}

/*
 * Returns 0 on success, -1 on failure.
 * Verifies the item exists before deleting.
 * Pass owner=NULL to skip ownership check.
 */
int delete_item_pk_sk(const char *prefix, const char *pk, const char *sk,
                      const char *owner) {
    const char *table = getenv("DYNAMO_TABLE_NAME");
    if (!table) {
        fprintf(stderr, "DYNAMO_TABLE_NAME not defined\n");
        return -1;
    }

    char *existing = get_item_pk_sk(prefix, pk, sk);
    if (!existing) {
        fprintf(stderr, "could not find %s %s %s\n", prefix, pk, sk);
        return -1;
    }

    if (owner && check_owner(existing, owner) != 0) {
        fprintf(stderr, "403\n");
        free(existing);
        return -1;
    }
    free(existing);

    char upper[64];
    str_upper(prefix, upper);
    char pk_val[512], sk_val[512];
    snprintf(pk_val, sizeof(pk_val), "%s#%s", upper, string_stem(pk));
    snprintf(sk_val, sizeof(sk_val), "%s#%s", upper, string_stem(sk));

    Buf body = {0};
    b_fmt(&body,
          "{\"TableName\":\"%s\","
          "\"Key\":{\"pk\":{\"S\":\"%s\"},\"sk\":{\"S\":\"%s\"}}}",
          table, pk_val, sk_val);

    char *resp = dynamo_request("DynamoDB_20120810.DeleteItem", body.b);
    free(body.b);
    if (!resp)
        return -1;
    free(resp);
    return 0;
}

void iso_timestamp(char *buf, size_t len) {
    time_t t = time(NULL);
    struct tm tm_info;
    gmtime_r(&t, &tm_info);
    strftime(buf, len, "%Y-%m-%dT%H:%M:%S.000Z", &tm_info);
}

int save_item_plain(const char *plain_json, const char *owner) {
    const char *table = getenv("DYNAMO_TABLE_NAME");
    if (!table) {
        fprintf(stderr, "DYNAMO_TABLE_NAME not defined\n");
        return -1;
    }

    if (owner && check_owner(plain_json, owner) != 0) {
        fprintf(stderr, "403\n");
        return -1;
    }

    char *wire = dynamo_marshal(plain_json);
    if (!wire) return -1;

    Buf body = {0};
    b_str(&body, "{\"TableName\":\"");
    b_str(&body, table);
    b_str(&body, "\",\"Item\":");
    b_str(&body, wire);
    b_chr(&body, '}');
    free(wire);

    char *resp = dynamo_request("DynamoDB_20120810.PutItem", body.b);
    free(body.b);
    if (!resp) return -1;
    free(resp);
    return 0;
}

/*
 * Deletes all items with the given pk, in batches of 25.
 * Returns the number of deleted items, or -1 on error.
 * Pass owner=NULL to skip ownership check.
 */
int delete_items_pk(const char *prefix, const char *pk, const char *owner) {
    const char *table = getenv("DYNAMO_TABLE_NAME");
    if (!table) {
        fprintf(stderr, "DYNAMO_TABLE_NAME not defined\n");
        return -1;
    }

    char upper[64];
    str_upper(prefix, upper);
    char pk_val[512];
    snprintf(pk_val, sizeof(pk_val), "%s#%s", upper, string_stem(pk));

    /* query all items with this pk, paginating */
    ItemList all = {0};
    char *last_key = NULL;

    do {
        Buf body = {0};
        b_fmt(&body,
              "{\"TableName\":\"%s\","
              "\"KeyConditionExpression\":\"pk = :pk\","
              "\"ExpressionAttributeValues\":{\":pk\":{\"S\":\"%s\"}}",
              table, pk_val);
        append_exclusive_start_key(&body, last_key);
        free(last_key);
        last_key = NULL;

        char *resp = dynamo_request("DynamoDB_20120810.Query", body.b);
        free(body.b);
        if (!resp) {
            item_list_free(&all);
            return -1;
        }

        ItemList page = parse_query_items(resp, &last_key);
        free(resp);

        /* merge page into all */
        if (page.count) {
            all.items =
                realloc(all.items, (all.count + page.count) * sizeof(char *));
            memcpy(all.items + all.count, page.items,
                   page.count * sizeof(char *));
            all.count += page.count;
            free(page.items);
        }
    } while (last_key);

    if (all.count == 0) {
        free(all.items);
        return 0;
    }

    /* ownership check */
    if (owner) {
        for (size_t i = 0; i < all.count; i++) {
            if (check_owner(all.items[i], owner) != 0) {
                fprintf(stderr, "403 on item %zu\n", i);
                item_list_free(&all);
                return -1;
            }
        }
    }

    /* batch delete in groups of 25 */
    int deleted = 0;
    for (size_t i = 0; i < all.count; i += 25) {
        size_t end = i + 25 < all.count ? i + 25 : all.count;

        Buf body = {0};
        b_str(&body, "{\"RequestItems\":{\"");
        b_str(&body, table);
        b_str(&body, "\":[");

        for (size_t j = i; j < end; j++) {
            if (j > i)
                b_chr(&body, ',');
            char *item_pk = json_get_string(all.items[j], "pk");
            char *item_sk = json_get_string(all.items[j], "sk");
            b_fmt(&body,
                  "{\"DeleteRequest\":{\"Key\":{"
                  "\"pk\":{\"S\":\"%s\"},"
                  "\"sk\":{\"S\":\"%s\"}"
                  "}}}",
                  item_pk ? item_pk : "", item_sk ? item_sk : "");
            free(item_pk);
            free(item_sk);
        }

        b_str(&body, "]}}");

        char *resp = dynamo_request("DynamoDB_20120810.BatchWriteItem", body.b);
        free(body.b);
        if (!resp) {
            item_list_free(&all);
            return -1;
        }
        free(resp);
        deleted += (int)(end - i);
    }

    item_list_free(&all);
    return deleted;
}

/*
 * Queries GSI "OWNER-DATATYPE-index".
 * Returns ItemList of unmarshalled items; caller must call item_list_free().
 */
ItemList get_items_owner_dt(const char *user_id, const char *datatype) {
    ItemList result = {0};
    const char *table = getenv("DYNAMO_TABLE_NAME");
    if (!table) {
        fprintf(stderr, "DYNAMO_TABLE_NAME not defined\n");
        return result;
    }

    char *last_key = NULL;
    do {
        Buf body = {0};
        b_fmt(&body,
              "{\"TableName\":\"%s\","
              "\"IndexName\":\"OWNER-DATATYPE-index\","
              "\"KeyConditionExpression\":\"#owner = :owner and DATATYPE = "
              ":datatype\","
              "\"ExpressionAttributeNames\":{\"#owner\":\"OWNER\"},"
              "\"ExpressionAttributeValues\":{"
              "\":owner\":{\"S\":\"%s\"},"
              "\":datatype\":{\"S\":\"%s\"}"
              "}",
              table, user_id, datatype);
        append_exclusive_start_key(&body, last_key);
        free(last_key);
        last_key = NULL;

        char *resp = dynamo_request("DynamoDB_20120810.Query", body.b);
        free(body.b);
        if (!resp) {
            item_list_free(&result);
            return (ItemList){0};
        }

        ItemList page = parse_query_items(resp, &last_key);
        free(resp);

        if (page.count) {
            result.items = realloc(result.items, (result.count + page.count) *
                                                     sizeof(char *));
            memcpy(result.items + result.count, page.items,
                   page.count * sizeof(char *));
            result.count += page.count;
            free(page.items);
        }
    } while (last_key);

    return result;
}
/*
 * Queries GSI "DATATYPE-pk-index" with pagination.
 * Returns ItemList of unmarshalled items; caller must call item_list_free().
 */
ItemList get_items_datatype_pk(const char *datatype, const char *pk) {
    ItemList result = {0};
    const char *table = getenv("DYNAMO_TABLE_NAME");
    if (!table) {
        fprintf(stderr, "DYNAMO_TABLE_NAME not defined\n");
        return result;
    }

    char pk_val[512];
    snprintf(pk_val, sizeof(pk_val), "%s#%s", datatype, string_stem(pk));

    char *last_key = NULL;
    do {
        Buf body = {0};
        b_fmt(
            &body,
            "{\"TableName\":\"%s\","
            "\"IndexName\":\"DATATYPE-pk-index\","
            "\"KeyConditionExpression\":\"DATATYPE = :datatype and pk = :pk\","
            "\"ExpressionAttributeValues\":{"
            "\":datatype\":{\"S\":\"%s\"},"
            "\":pk\":{\"S\":\"%s\"}"
            "}",
            table, datatype, pk_val);
        append_exclusive_start_key(&body, last_key);
        free(last_key);
        last_key = NULL;

        char *resp = dynamo_request("DynamoDB_20120810.Query", body.b);
        free(body.b);
        if (!resp) {
            item_list_free(&result);
            return (ItemList){0};
        }

        ItemList page = parse_query_items(resp, &last_key);
        free(resp);

        if (page.count) {
            result.items = realloc(result.items, (result.count + page.count) *
                                                     sizeof(char *));
            memcpy(result.items + result.count, page.items,
                   page.count * sizeof(char *));
            result.count += page.count;
            free(page.items);
        }
    } while (last_key);

    return result;
}

/*
 * Queries GSI "OWNER-pk-index" with pagination.
 * Returns ItemList of unmarshalled items; caller must call item_list_free().
 */
ItemList get_items_owner_pk(const char *prefix, const char *user_id,
                            const char *aid) {
    ItemList result = {0};
    const char *table = getenv("DYNAMO_TABLE_NAME");
    if (!table) {
        fprintf(stderr, "DYNAMO_TABLE_NAME not defined\n");
        return result;
    }

    char pk_val[512];
    snprintf(pk_val, sizeof(pk_val), "%s#%s", prefix, string_stem(aid));
    int pages = 0;
    char *last_key = NULL;
    do {
        Buf body = {0};
        b_fmt(&body,
              "{\"TableName\":\"%s\","
              "\"IndexName\":\"OWNER-pk-index\","
              "\"KeyConditionExpression\":\"#owner = :owner and #pk = :pk\","
              "\"ExpressionAttributeNames\":{\"#owner\":\"OWNER\",\"#pk\":"
              "\"pk\"},"
              "\"ExpressionAttributeValues\":{"
              "\":owner\":{\"S\":\"%s\"},"
              "\":pk\":{\"S\":\"%s\"}"
              "}",
              table, user_id, pk_val);
        append_exclusive_start_key(&body, last_key);
        free(last_key);
        last_key = NULL;

        char *resp = dynamo_request("DynamoDB_20120810.Query", body.b);
        free(body.b);
        if (!resp) {
            item_list_free(&result);
            return (ItemList){0};
        }

        ItemList page = parse_query_items(resp, &last_key);
        free(resp);
        printf("pages: %d", pages++);
        if (page.count) {
            result.items = realloc(result.items, (result.count + page.count) *
                                                     sizeof(char *));
            memcpy(result.items + result.count, page.items,
                   page.count * sizeof(char *));
            result.count += page.count;
            free(page.items);
        }
    } while (last_key);

    return result;
}

ItemList get_items_owner_dt_proj(const char *user_id, const char *datatype,
                                  const char *proj_expr, const char *extra_names) {
    ItemList result = {0};
    const char *table = getenv("DYNAMO_TABLE_NAME");
    if (!table) {
        fprintf(stderr, "DYNAMO_TABLE_NAME not defined\n");
        return result;
    }

    char *last_key = NULL;
    do {
        Buf body = {0};
        b_fmt(&body,
              "{\"TableName\":\"%s\","
              "\"IndexName\":\"OWNER-DATATYPE-index\","
              "\"KeyConditionExpression\":\"#owner = :owner and DATATYPE = :datatype\","
              "\"ProjectionExpression\":\"%s\","
              "\"ExpressionAttributeNames\":{\"#owner\":\"OWNER\"",
              table, proj_expr);
        if (extra_names && extra_names[0]) {
            b_str(&body, ",");
            b_str(&body, extra_names);
        }
        b_fmt(&body,
              "},"
              "\"ExpressionAttributeValues\":{"
              "\":owner\":{\"S\":\"%s\"},"
              "\":datatype\":{\"S\":\"%s\"}"
              "}",
              user_id, datatype);
        append_exclusive_start_key(&body, last_key);
        free(last_key);
        last_key = NULL;

        char *resp = dynamo_request("DynamoDB_20120810.Query", body.b);
        free(body.b);
        if (!resp) {
            item_list_free(&result);
            return (ItemList){0};
        }

        ItemList page = parse_query_items(resp, &last_key);
        free(resp);

        if (page.count) {
            result.items = realloc(result.items, (result.count + page.count) *
                                                     sizeof(char *));
            memcpy(result.items + result.count, page.items,
                   page.count * sizeof(char *));
            result.count += page.count;
            free(page.items);
        }
    } while (last_key);

    return result;
}

int http_post(const char *url, const char *payload) {
    CURL *curl = get_curl(&tl_http_curl);
    if (!curl)
        return -1;

    struct curl_slist *hdrs = NULL;
    hdrs = curl_slist_append(hdrs, "Content-Type: application/json");

    ResponseBuf resp = {0};
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &resp);

    CURLcode res = curl_easy_perform(curl);
    curl_slist_free_all(hdrs);
    free(resp.data);

    return (res == CURLE_OK) ? 0 : -1;
}

int invoke_lambda(const char *function_name, const char *payload) {
    const char *key_id = getenv("AWS_ACCESS_KEY_ID");
    const char *secret = getenv("AWS_SECRET_ACCESS_KEY");
    const char *region = getenv("AWS_REGION");

    if (!key_id || !secret || !region) {
        fprintf(stderr, "AWS credentials/region missing\n");
        return -1;
    }

    char url[512], userpwd[256], sigv4[128];
    snprintf(url, sizeof(url),
             "https://lambda.%s.amazonaws.com/2015-03-31/functions/%s/invocations",
             region, function_name);
    snprintf(userpwd, sizeof(userpwd), "%s:%s", key_id, secret);
    snprintf(sigv4, sizeof(sigv4), "aws:amz:%s:lambda", region);

    CURL *curl = get_curl(&tl_lambda_curl);
    if (!curl)
        return -1;

    struct curl_slist *hdrs = NULL;
    hdrs = curl_slist_append(hdrs, "Content-Type: application/json");
    hdrs = curl_slist_append(hdrs, "X-Amz-Invocation-Type: Event");

    ResponseBuf resp = {0};
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
    curl_easy_setopt(curl, CURLOPT_AWS_SIGV4, sigv4);
    curl_easy_setopt(curl, CURLOPT_USERPWD, userpwd);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &resp);

    CURLcode res = curl_easy_perform(curl);
    curl_slist_free_all(hdrs);
    free(resp.data);

    return (res == CURLE_OK) ? 0 : -1;
}

char *http_post_sync(const char *url, const char *payload) {
    CURL *curl = get_curl(&tl_http_curl);
    if (!curl)
        return NULL;

    struct curl_slist *hdrs = NULL;
    hdrs = curl_slist_append(hdrs, "Content-Type: application/json");

    ResponseBuf resp = {0};
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &resp);

    CURLcode res = curl_easy_perform(curl);
    curl_slist_free_all(hdrs);

    if (res != CURLE_OK) {
        free(resp.data);
        return NULL;
    }
    return resp.data;
}

char *invoke_lambda_sync(const char *function_name, const char *payload) {
    const char *key_id = getenv("AWS_ACCESS_KEY_ID");
    const char *secret = getenv("AWS_SECRET_ACCESS_KEY");
    const char *region = getenv("AWS_REGION");

    if (!key_id || !secret || !region) {
        fprintf(stderr, "AWS credentials/region missing\n");
        return NULL;
    }

    char url[512], userpwd[256], sigv4[128];
    snprintf(url, sizeof(url),
             "https://lambda.%s.amazonaws.com/2015-03-31/functions/%s/invocations",
             region, function_name);
    snprintf(userpwd, sizeof(userpwd), "%s:%s", key_id, secret);
    snprintf(sigv4, sizeof(sigv4), "aws:amz:%s:lambda", region);

    CURL *curl = get_curl(&tl_lambda_curl);
    if (!curl)
        return NULL;

    struct curl_slist *hdrs = NULL;
    hdrs = curl_slist_append(hdrs, "Content-Type: application/json");

    ResponseBuf resp = {0};
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
    curl_easy_setopt(curl, CURLOPT_AWS_SIGV4, sigv4);
    curl_easy_setopt(curl, CURLOPT_USERPWD, userpwd);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &resp);

    CURLcode res = curl_easy_perform(curl);
    curl_slist_free_all(hdrs);

    if (res != CURLE_OK) {
        free(resp.data);
        return NULL;
    }
    return resp.data;
}

int save_item(const char *item_json, const char *owner) {
    const char *table = getenv("DYNAMO_TABLE_NAME");
    if (!table) {
        fprintf(stderr, "DYNAMO_TABLE_NAME not defined\n");
        return -1;
    }

    /* unmarshal temporarily just for the owner check */
    if (owner) {
        char *plain = dynamo_unmarshal(item_json);
        int ok = check_owner(plain, owner);
        free(plain);
        if (ok != 0) {
            fprintf(stderr, "403\n");
            return -1;
        }
    }

    Buf body = {0};
    b_str(&body, "{\"TableName\":\"");
    b_str(&body, table);
    b_str(&body, "\",\"Item\":");
    b_str(&body, item_json);
    b_chr(&body, '}');

    char *resp = dynamo_request("DynamoDB_20120810.PutItem", body.b);
    free(body.b);
    if (!resp)
        return -1;
    free(resp);
    return 0;
}
