# EQEmu_working_power_source

# 🌟 Power Source Purity Scaling System  
### *Dynamic item scaling based on total purity across all worn gear — EQEmu compatible*

This system lets you create **custom power sources or charm-slot items** whose stats scale dynamically based on **total purity worn by the player**.  
Perfect for custom servers, progression environments, or custom gearing systems.

---

## 🔧 Features

✔ **Reads purity from all equipped visible armor slots**  
✔ **No constant timers** — scales *only when EQEmu calls* `EVENT_SCALE_CALC`  
✔ **Lightweight plugin (optional DB caching)**  
✔ **Works with any item using a charm file**  
✔ Supports **custom scale curves**  
✔ 100% server-side — no client edits  
✔ Compatible with **EQEmu current Perl API**

---

# 📦 Installation

### 1️⃣ Drop Plugin in Place  
Place in:

```
server/quests/plugins/power_source_scaling.pl
```

### 2️⃣ Add `TYPE = 10` and slot the item in Power Source  
In `items` table:

```
type = 10        (Armor)
```

Make sure item is wearable in powersource slot.

### 3️⃣ Add Purity to Gear  
All worn gear that contributes purity must have:

```
items.purity > 0
```

### 4️⃣ Create a Charm File for the Power Source Item  

Example:

```
server/quests/items/147705.pl
```

---

# 💠 Charm File Example  
(Scales stats based on TOTAL purity of all worn items)

```perl
sub EVENT_SCALE_CALC {
    return unless $client;

    # Pull total purity across worn gear
    my $purity = plugin::powersource_total_purity($client);

    # Clamp sanity range
    $purity = 0   if $purity < 0;
    $purity = 800 if $purity > 800;  # soft cap

    my $scale;

    # Custom scale curve (modify freely)
    if ($purity < 50) {
        $scale = $purity / 200;                   # 0.00 → 0.25
    }
    elsif ($purity < 100) {
        $scale = 0.25 + ($purity - 50) / 150;     # 0.25 → 0.58
    }
    elsif ($purity < 200) {
        $scale = 0.60 + ($purity - 100) / 150;    # 0.60 → 1.26
    }
    elsif ($purity < 400) {
        $scale = 1.30 + ($purity - 200) / 200;    # 1.30 → 2.30
    }
    else {
        $scale = 2.30 + ($purity - 400) / 300;    # up to ~3.9
    }

    $questitem->SetScale($scale);
}
```
Or if you want something simpler
```
sub EVENT_SCALE_CALC {
    my $purity = plugin::powersource_total_purity($client);

    $purity = 0   if $purity < 0;
    $purity = 300 if $purity > 300;

    my $scale = $purity / 300.0;

    $questitem->SetScale($scale);
}
```

---

# 🔍 Debug Purity Manually (Optional)

Add to `global_player.pl`:

```perl
if ($text =~ /^\?purity\b/i) {
    my $total = plugin::powersource_total_purity($client);
    $client->Message(15, "[PS] Total purity on worn gear = $total");
}
```

Use in game:

```
/say ?purity
```

---

# 🧠 How the Scaling Curve Works

The curve is progressive:

| Purity Range | Resulting Scale |
|--------------|----------------|
| 0–49         | 0.00 → 0.25 |
| 50–99        | 0.25 → 0.58 |
| 100–199      | 0.60 → 1.26 |
| 200–399      | 1.30 → 2.30 |
| 400–800      | 2.30 → ~3.90 |

Modify the curve however you want — linear, exponential, softcaps.

---

# 📜 License

Do whatever you want with it. Credit appreciated but not required.

---

# ❤️ Support & Contributions

If you expand this system—new curves, tiered power sources, purity-driven augments—PRs are welcome!

Place this plugin in:
