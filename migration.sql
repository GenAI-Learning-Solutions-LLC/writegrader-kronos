CREATE TABLE IF NOT EXISTS fetch_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    data_type TEXT NOT NULL,
    name TEXT NOT NULL,
    user TEXT NOT NULL,

    data TEXT DEFAULT '{}',
    created_at DATETIME DEFAULT (datetime('now', 'utc')),
    updated_at DATETIME DEFAULT (datetime('now', 'utc')),
    UNIQUE(name, user, data_type)
);
CREATE TRIGGER IF NOT EXISTS fetch_cache_updated_at
AFTER UPDATE ON fetch_cache
FOR EACH ROW
BEGIN
    UPDATE fetch_cache SET updated_at = datetime('now', 'utc') WHERE id = OLD.id;
END; 



CREATE TABLE IF NOT EXISTS task_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    data_type TEXT NOT NULL,
    code INTEGER NOT NULL,
    user TEXT NOT NULL,
    status TEXT NOT NULL,
    data TEXT DEFAULT '{}',
    created_at DATETIME DEFAULT (datetime('now', 'utc')),
    updated_at DATETIME DEFAULT (datetime('now', 'utc')),
    UNIQUE(code)
);
CREATE TRIGGER IF NOT EXISTS task_queue_updated_at
AFTER UPDATE ON task_queue 
FOR EACH ROW
BEGIN
    UPDATE task_queue SET updated_at = datetime('now', 'utc') WHERE id = OLD.id;
END; 



