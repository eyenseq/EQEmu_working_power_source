package plugin;
use DBI;

# =========================================================
# Power Source / Purity Plugin
#  - Minimal version: just exposes total purity helper
#  - Used by item charm scripts via EVENT_SCALE_CALC
#
#  Public:
#    plugin::powersource_recalc($client)        # call on EVENT_ENTERZONE
#    plugin::powersource_total_purity($client)  # call from EVENT_SCALE_CALC
# =========================================================

# --- DB config for purity lookup (WORLD DB) ---
our $PS_DBH;
our $PS_DB_HOST = $ENV{DB_HOST}     // '127.0.0.1';
our $PS_DB_PORT = $ENV{DB_PORT}     // 3306;
our $PS_DB_NAME = $ENV{DB_NAME}     // 'peq';
our $PS_DB_USER = $ENV{DB_USER}     // 'eqemu';
our $PS_DB_PASS = $ENV{DB_PASSWORD} // '';
our $PS_DBI_EXTRA = $ENV{DBI_EXTRA} // 'mysql_enable_utf8=1';

# If your schema is different, change these:
our $PS_ITEMS_TABLE   = 'items';
our $PS_PURITY_COLUMN = 'purity';

our $PS_STH_PURITY;
our %PS_PURITY_CACHE;   # per-item purity cache
our %PS_TOTAL_CACHE;    # per-char total purity cache

# Debug to zone log only (no client spam)
our $PS_DEBUG = 0;

# Worn slots that contribute purity
#  0 = charm          11 = range
#  1 = left ear       12 = hands
#  2 = head           13 = primary
#  3 = face           14 = secondary
#  4 = right ear      15 = left ring
#  5 = neck           16 = right ring
#  6 = shoulders      17 = chest
#  7 = arms           18 = legs
#  8 = back           19 = feet
#  9 = left wrist     20 = waist
# 10 = right wrist    22 = ammo
my @PS_VISIBLE_SLOTS = (
    0,   # charm
    1,   # left ear
    2,   # head
    3,   # face
    4,   # right ear
    5,   # neck
    6,   # shoulders
    7,   # arms
    8,   # back
    9,   # left wrist
    10,  # right wrist
    11,  # range
    12,  # hands
    13,  # primary
    14,  # secondary
    15,  # left ring
    16,  # right ring
    17,  # chest
    18,  # legs
    19,  # feet
    20,  # waist
);

# ---------------------------------------------------------
# Internal: DB handle
# ---------------------------------------------------------
sub _ps_dbh {
    return $PS_DBH if $PS_DBH && eval { $PS_DBH->ping };

    my $dsn = "DBI:mysql:database=$PS_DB_NAME;host=$PS_DB_HOST;port=$PS_DB_PORT;$PS_DBI_EXTRA";
    my $dbh = DBI->connect(
        $dsn, $PS_DB_USER, $PS_DB_PASS,
        { RaiseError => 0, PrintError => 0, AutoCommit => 1 }
    );

    if (!$dbh) {
        quest::debug("[PS] ERROR: cannot connect DB for purity lookup: $DBI::errstr (dsn=$dsn user=$PS_DB_USER)")
          if $PS_DEBUG;
        return;
    }

    $PS_DBH = $dbh;
    $PS_STH_PURITY = undef; # force re-prepare next time

    quest::debug("[PS] Connected to DB [$PS_DB_NAME] at [$PS_DB_HOST:$PS_DB_PORT] as [$PS_DB_USER]")
      if $PS_DEBUG;

    return $PS_DBH;
}

# ---------------------------------------------------------
# Internal: get purity for a single item_id
# ---------------------------------------------------------
sub _ps_get_item_purity_from_db {
    my ($item_id) = @_;
    return 0 if !$item_id;

    # cache to avoid constant lookups
    if (exists $PS_PURITY_CACHE{$item_id}) {
        return $PS_PURITY_CACHE{$item_id};
    }

    my $dbh = _ps_dbh() or do {
        quest::debug("[PS] _ps_dbh() failed; cannot look up purity for item_id=$item_id")
          if $PS_DEBUG;
        return 0;
    };

    if (!$PS_STH_PURITY) {
        my $sql = "SELECT $PS_PURITY_COLUMN FROM $PS_ITEMS_TABLE WHERE id = ?";
        $PS_STH_PURITY = $dbh->prepare($sql);
        if (!$PS_STH_PURITY) {
            quest::debug("[PS] ERROR: prepare failed for purity query: $DBI::errstr")
              if $PS_DEBUG;
            return 0;
        } else {
            quest::debug("[PS] Prepared purity query: $sql")
              if $PS_DEBUG;
        }
    }

    my $purity = 0;
    if ($PS_STH_PURITY) {
        if (!$PS_STH_PURITY->execute($item_id)) {
            quest::debug("[PS] ERROR: execute failed for item_id=$item_id: $DBI::errstr")
              if $PS_DEBUG;
        } else {
            ($purity) = $PS_STH_PURITY->fetchrow_array();
            $purity ||= 0;
            quest::debug("[PS] DB purity lookup: item_id=$item_id purity=$purity")
              if $PS_DEBUG;
        }
    }

    $PS_PURITY_CACHE{$item_id} = $purity;
    return $purity;
}

# ---------------------------------------------------------
# INTERNAL: _ps_calc_total_purity($client)
#   Does the real work: scan gear, hit DB, sum purity.
#   Called only when zoning (or manual recalc).
# ---------------------------------------------------------
sub _ps_calc_total_purity {
    my ($client) = @_;
    return 0 if !$client;

    my $name         = $client->GetName();
    my $total_purity = 0;

    quest::debug("[PS] Recalculating purity for $name")
      if $PS_DEBUG;

    foreach my $slot (@PS_VISIBLE_SLOTS) {
        my $item_id = $client->GetItemIDAt($slot) || 0;
        next if !$item_id;

        my $purity = _ps_get_item_purity_from_db($item_id);
        next if !$purity || $purity <= 0;

        $total_purity += $purity;

        quest::debug(
            sprintf(
                "[PS] slot=%02d item_id=%d purity=%d",
                $slot, $item_id, $purity
            )
        ) if $PS_DEBUG;
    }

    quest::debug("[PS] total_purity=$total_purity for $name")
      if $PS_DEBUG;

    return $total_purity;
}

# ---------------------------------------------------------
# PUBLIC: plugin::powersource_recalc($client)
#   Call this on EVENT_ENTERZONE.
#   - Runs full calc once
#   - Caches in memory and in data bucket
# ---------------------------------------------------------
sub powersource_recalc {
    my ($client) = @_;
    return 0 if !$client;

    my $charid = $client->CharacterID() || 0;
    my $name   = $client->GetName();

    my $total = _ps_calc_total_purity($client);

    if ($charid) {
        # in-memory cache
        $PS_TOTAL_CACHE{$charid} = $total;

        # data bucket cache (survives script reload)
        my $key = "ps:total:$charid";
        quest::set_data($key, $total, "H1");   # 1 hour TTL is plenty
    }

    quest::debug("[PS] Zone-in recalc for $name (charid=$charid): total_purity=$total")
      if $PS_DEBUG;

    return $total;
}

# ---------------------------------------------------------
# PUBLIC: plugin::powersource_total_purity($client)
#   Lightweight: no DB, just returns cached/bucket value.
#   Intended to be called from EVENT_SCALE_CALC.
# ---------------------------------------------------------
sub powersource_total_purity {
    my ($client) = @_;
    return 0 if !$client;

    my $charid = $client->CharacterID() || 0;
    return 0 if !$charid;

    # 1) Check in-memory cache first
    if (exists $PS_TOTAL_CACHE{$charid}) {
        return $PS_TOTAL_CACHE{$charid};
    }

    # 2) Fallback to data bucket (in case plugin reloaded mid-zone)
    my $key    = "ps:total:$charid";
    my $stored = quest::get_data($key);
    return $stored || 0;
}

1;





