CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event TEXT NOT NULL,
    user_email TEXT NOT NULL,
    user_group TEXT NOT NULL,
    json_data TEXT NOT NULL CHECK (json_valid(json_data)),
    timestamp DATETIME DEFAULT (datetime('now', 'utc'))
);

CREATE TABLE IF NOT EXISTS task_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task TEXT NOT NULL,
    step INTEGER DEFAULT 0,
    reference TEXT,
    token TEXT NOT NULL, -- used for other services to be able to make updates to a specific task
    user_email TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'ready' CHECK (status IN ('ready', 'stopped', 'running', 'complete', 'error')),
    is_complete INTEGER DEFAULT 0,
    meta_data TEXT NOT NULL CHECK (json_valid(meta_data)),
    created_at DATETIME DEFAULT (datetime('now', 'utc')),
    updated_at DATETIME DEFAULT (datetime('now', 'utc'))
);

CREATE TRIGGER IF NOT EXISTS task_queue_updated_at
AFTER UPDATE ON task_queue 
FOR EACH ROW
BEGIN
    UPDATE task_queue SET updated_at = datetime('now', 'utc') WHERE id = OLD.id;
END; 

CREATE TABLE IF NOT EXISTS chats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token TEXT NOT NULL,
    user_email TEXT NOT NULL,
    is_user INTEGER DEFAULT 0,
    content TEXT NOT NULL CHECK (json_valid(content)),
    timestamp DATETIME DEFAULT (datetime('now', 'utc'))
);



CREATE TABLE IF NOT EXISTS fetch_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    data_type TEXT NOT NULL,
    name TEXT NOT NULL,
    user_email TEXT NOT NULL,

    data TEXT DEFAULT '{}',
    created_at DATETIME DEFAULT (datetime('now', 'utc')),
    updated_at DATETIME DEFAULT (datetime('now', 'utc')),
    UNIQUE(name, user_email, data_type)
);
CREATE TRIGGER IF NOT EXISTS fetch_cache_updated_at
AFTER UPDATE ON fetch_cache
FOR EACH ROW
BEGIN
    UPDATE fetch_cache SET updated_at = datetime('now', 'utc') WHERE id = OLD.id;
END; 



