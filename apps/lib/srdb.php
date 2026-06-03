<?php
/**
 * srdb.php — serialization-safe search/replace (Task P3.1, DESIGN §6.3)
 *
 * Replaces a string across a WordPress database while correctly handling PHP
 * serialized data (widgets, theme mods, page-builder settings) — recursively
 * unserialize, replace, re-serialize, so length headers stay valid. This is the
 * wp-cli-free equivalent of `wp search-replace`, using only PHP + mysqli, both of
 * which are already required on a WordPress server. NO new dependency.
 *
 * Connection via env: SRDB_HOST SRDB_DB SRDB_USER SRDB_PASS [SRDB_SOCKET]
 * Args:               <table_prefix> <old-string> <new-string>
 */

if ($argc < 4) { fwrite(STDERR, "usage: srdb.php <prefix> <old> <new>\n"); exit(2); }
list(, $prefix, $old, $new) = $argv;

$host = getenv('SRDB_HOST') ?: 'localhost';
$db   = getenv('SRDB_DB');
$user = getenv('SRDB_USER');
$pass = getenv('SRDB_PASS');
$sock = getenv('SRDB_SOCKET') ?: null;

mysqli_report(MYSQLI_REPORT_OFF);
$m = $sock
    ? new mysqli(null, $user, $pass, $db, 0, $sock)
    : new mysqli($host, $user, $pass, $db);
if ($m->connect_errno) { fwrite(STDERR, "connect failed: {$m->connect_error}\n"); exit(1); }

/** Recursively replace inside strings/arrays/objects (serialization-aware). */
function srep($data, $old, $new) {
    if (is_string($data)) return str_replace($old, $new, $data);
    if (is_array($data)) {
        $out = [];
        foreach ($data as $k => $v) {
            $out[is_string($k) ? str_replace($old, $new, $k) : $k] = srep($v, $old, $new);
        }
        return $out;
    }
    if (is_object($data)) {
        foreach (get_object_vars($data) as $k => $v) $data->$k = srep($v, $old, $new);
        return $data;
    }
    return $data;
}

/** Replace within one value, preserving serialization if it is serialized. */
function fix($val, $old, $new) {
    $u = @unserialize($val);
    if ($u !== false || $val === 'b:0;') return serialize(srep($u, $old, $new));
    return str_replace($old, $new, $val);
}

// Tables/columns that hold URLs (incl. serialized ones).
$targets = [
    ["{$prefix}options",  "option_id", "option_value"],
    ["{$prefix}postmeta", "meta_id",   "meta_value"],
    ["{$prefix}posts",    "ID",        "post_content"],
    ["{$prefix}posts",    "ID",        "guid"],
];

$changed = 0;
$esc = $m->real_escape_string($old);
foreach ($targets as list($table, $pk, $col)) {
    $res = @$m->query("SELECT `$pk`, `$col` FROM `$table` WHERE `$col` LIKE '%{$esc}%'");
    if (!$res) continue;   // table may not exist for a given install
    while ($row = $res->fetch_assoc()) {
        $nv = fix($row[$col], $old, $new);
        if ($nv !== $row[$col]) {
            $st = $m->prepare("UPDATE `$table` SET `$col` = ? WHERE `$pk` = ?");
            $st->bind_param("ss", $nv, $row[$pk]);
            $st->execute();
            $changed++;
        }
    }
}
echo "replaced in {$changed} row(s)\n";
