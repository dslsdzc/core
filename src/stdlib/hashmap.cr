// === hashmap.cr ===
// Open-addressing integer hash map (int -> int).
//
// Capacity, growth ratio, load factor, hash seed and hash algorithm are all
// constructor parameters. The table uses linear probing with tombstones; keys
// and values live in raw cell buffers, occupancy is a byte per slot.
//
import internal::bytes
import internal::word

pub struct IntMap:
    keys: string
    values: string
    used: string
    cap: int
    count: int
    growth_num: int
    growth_den: int
    load_num: int
    load_den: int
    seed: int
    hash_kind: int

fn intMapNextPow2(n: int) -> int:
    c : ., mut = 1
    loop:
        if c >= n:
            return c
        c = c * 2
    return c

fn intMapHash(key: int, seed: int, kind: int) -> int:
    x := wordNorm(key + seed, 32)
    if kind == 0:
        // murmur3-style 32-bit finalizer (one round)
        x = wordXor(x, wordShr(x, 16, 32), 32)
        x = wordMul(x, 2246822519, 32)
        x = wordXor(x, wordShr(x, 13, 32), 32)
        x = wordMul(x, 3266489917, 32)
        return wordXor(x, wordShr(x, 16, 32), 32)
    if kind == 1:
        // golden-ratio multiply-xor
        x = wordMul(x, 2654435761, 32)
        return wordXor(x, wordShr(x, 16, 32), 32)
    if kind == 2:
        // deliberately weak identity-xor
        return wordXor(x, wordShr(x, 16, 32), 32)
    // kind 3: heavy collisions (7 buckets) for linear-probing tests
    return wordNorm(key, 32) % 7

fn intMapGrow(m: IntMap) -> IntMap:
    old_cap := m.cap
    old_keys := m.keys
    old_values := m.values
    old_used := m.used
    next : ., mut = 0
    if m.growth_den > 0:
        next = old_cap * m.growth_num / m.growth_den
    if next <= old_cap:
        next = old_cap * 2
    new_cap := intMapNextPow2(next)
    keys := alloc(new_cap * 8)
    values := alloc(new_cap * 8)
    used := alloc(new_cap + 1)
    i : ., mut = 0
    loop:
        if i >= new_cap:
            break
        byteStore(used, i, 0)
        i = i + 1
    byteStore(used, new_cap, 0)
    out := IntMap { keys = keys, values = values, used = used, cap = new_cap, count = 0, growth_num = m.growth_num, growth_den = m.growth_den, load_num = m.load_num, load_den = m.load_den, seed = m.seed, hash_kind = m.hash_kind }
    i = 0
    loop:
        if i >= old_cap:
            break
        if byteLoad(old_used, i) == 1:
            k := cell_load(old_keys, i * 8)
            v := cell_load(old_values, i * 8)
            slot := out.findSlot(k)
            if slot >= 0:
                cell_store(out.keys, slot * 8, k)
                cell_store(out.values, slot * 8, v)
                byteStore(out.used, slot, 1)
                out.count = out.count + 1
        i = i + 1
    return out

fn intMapWith(initial_cap: int, growth_num: int, growth_den: int, load_num: int, load_den: int, seed: int, hash_kind: int) -> IntMap, pub:
    cap := intMapNextPow2(initial_cap)
    if cap < 4:
        cap = 4
    keys := alloc(cap * 8)
    values := alloc(cap * 8)
    used := alloc(cap + 1)
    i : ., mut = 0
    loop:
        if i >= cap:
            break
        byteStore(used, i, 0)
        i = i + 1
    byteStore(used, cap, 0)
    return IntMap { keys = keys, values = values, used = used, cap = cap, count = 0, growth_num = growth_num, growth_den = growth_den, load_num = load_num, load_den = load_den, seed = seed, hash_kind = hash_kind }

fn intMap() -> IntMap, pub:
    return intMapWith(16, 2, 1, 3, 4, 0, 0)

impl IntMap:
    fn findKey(&self, key: int) -> int:
        idx := intMapHash(key, self.seed, self.hash_kind) % self.cap
        i : ., mut = 0
        loop:
            if i >= self.cap:
                return -1
            st := byteLoad(self.used, idx)
            if st == 0:
                return -1
            if st == 1 && cell_load(self.keys, idx * 8) == key:
                return idx
            idx = (idx + 1) % self.cap
            i = i + 1
        return -1

    fn findSlot(&self, key: int) -> int:
        idx := intMapHash(key, self.seed, self.hash_kind) % self.cap
        tomb : ., mut = -1
        i : ., mut = 0
        loop:
            if i >= self.cap:
                if tomb >= 0:
                    return tomb
                return -1
            st := byteLoad(self.used, idx)
            if st == 0:
                if tomb >= 0:
                    return tomb
                return idx
            if st == 2:
                if tomb < 0:
                    tomb = idx
            else:
                if cell_load(self.keys, idx * 8) == key:
                    return idx
            idx = (idx + 1) % self.cap
            i = i + 1
        return tomb

    fn put(&mut self, key: int, value: int), pub:
        if self.load_den <= 0:
            self.load_den = 1
        if (self.count + 1) * self.load_den > self.cap * self.load_num:
            grown := intMapGrow(self)
            self.keys = grown.keys
            self.values = grown.values
            self.used = grown.used
            self.cap = grown.cap
            self.count = grown.count
        slot := self.findSlot(key)
        if slot < 0:
            return
        st := byteLoad(self.used, slot)
        cell_store(self.values, slot * 8, value)
        if st != 1:
            cell_store(self.keys, slot * 8, key)
            byteStore(self.used, slot, 1)
            self.count = self.count + 1

    fn get(&self, key: int) -> int, pub:
        slot := self.findKey(key)
        if slot < 0:
            return 0
        return cell_load(self.values, slot * 8)

    fn has(&self, key: int) -> bool, pub:
        return self.findKey(key) >= 0

    fn remove(&mut self, key: int), pub:
        slot := self.findKey(key)
        if slot >= 0:
            byteStore(self.used, slot, 2)
            self.count = self.count - 1

    fn size(&self) -> int, pub:
        return self.count

    fn capacity(&self) -> int, pub:
        return self.cap

    fn clear(&mut self), pub:
        i : ., mut = 0
        loop:
            if i >= self.cap:
                break
            byteStore(self.used, i, 0)
            i = i + 1
        self.count = 0
