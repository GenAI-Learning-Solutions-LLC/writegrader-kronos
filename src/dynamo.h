#ifndef DYNAMO_H
#define DYNAMO_H

#include <stddef.h>

/* ================================================================== */
/* types                                                                */
/* ================================================================== */

typedef struct {
    char  **items;
    size_t  count;
} ItemList;

/* ================================================================== */
/* item list                                                            */
/* ================================================================== */

void item_list_free(ItemList *l);

/* ================================================================== */
/* unmarshal                                                            */
/* ================================================================== */

/* strips DynamoDB type annotations; returns heap-allocated JSON, caller frees */
char *dynamo_unmarshal(const char *json);

/* ================================================================== */
/* ownership                                                            */
/* ================================================================== */

/* returns 0 if owner check passes, -1 if forbidden */
int check_owner(const char *item_json, const char *owner);

/* ================================================================== */
/* operations                                                           */
/* ================================================================== */

/* returns heap-allocated unmarshalled JSON of Item, or NULL; caller frees */
char *get_item_pk_sk(const char *prefix, const char *pk, const char *sk);

/* returns 0 on success, -1 on failure */
int delete_item_pk_sk(const char *prefix, const char *pk, const char *sk,
                      const char *owner);

/* returns number of deleted items, or -1 on failure */
int delete_items_pk(const char *prefix, const char *pk, const char *owner);

/* queries OWNER-DATATYPE-index */
ItemList get_items_owner_dt(const char *user_id, const char *datatype);

/* queries DATATYPE-pk-index, paginated */
ItemList get_items_datatype_pk(const char *datatype, const char *pk);

/* queries OWNER-pk-index, paginated */
ItemList get_items_owner_pk(const char *prefix, const char *user_id,
                            const char *aid);

/*
 * item_json must be in DynamoDB wire format (with type annotations).
 * returns 0 on success, -1 on failure.
 */
int save_item(const char *item_json, const char *owner);

#endif /* DYNAMO_H */
