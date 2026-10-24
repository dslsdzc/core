import bigint

fn expect_cmp(v: int, text: string, code: int) -> int:
    if bi_cmp(v, bi_from_dec(text)) != 0:
        return code
    return 0

fn expect_dec(v: int, text: string, code: int) -> int:
    if str_eq(bi_to_dec(v), text) == 0:
        return code
    return 0

fn main() -> int:
    z := bi_from_dec("0")
    if bi_is_zero(z) == 0:
        return 1
    if expect_cmp(bi_add(bi_from_dec("1"), bi_from_dec("2")), "3", 2) != 0:
        return 2
    if expect_cmp(bi_add(bi_from_dec("-1"), bi_from_dec("2")), "1", 3) != 0:
        return 3
    if expect_cmp(bi_sub(bi_from_dec("1"), bi_from_dec("2")), "-1", 4) != 0:
        return 4
    if expect_cmp(bi_mul(bi_from_dec("123456789"), bi_from_dec("987654321")), "121932631112635269", 5) != 0:
        return 5
    big := bi_from_dec("1267650600228229401496703205376")
    if expect_cmp(bi_add(big, bi_from_dec("1")), "1267650600228229401496703205377", 6) != 0:
        return 6
    if expect_cmp(bi_mul(bi_from_dec("1000000000000000"), bi_from_dec("1000000000000000")), "1000000000000000000000000000000", 7) != 0:
        return 7
    if expect_cmp(bi_add(bi_from_dec("4611686018427387904"), bi_from_dec("1")), "4611686018427387905", 15) != 0:
        return 15
    if expect_cmp(bi_add(bi_from_dec("-4611686018427387905"), bi_from_dec("1")), "-4611686018427387904", 16) != 0:
        return 16
    if expect_cmp(bi_div(bi_from_dec("1267650600228229401496703205376"), bi_from_dec("3")), "422550200076076467165567735125", 17) != 0:
        return 17
    if expect_cmp(bi_mod(bi_from_dec("1267650600228229401496703205376"), bi_from_dec("3")), "1", 18) != 0:
        return 18
    if expect_cmp(bi_div(bi_from_dec("-1267650600228229401496703205376"), bi_from_dec("7")), "-181092942889747057356671886482", 19) != 0:
        return 19
    if expect_cmp(bi_mod(bi_from_dec("-1267650600228229401496703205376"), bi_from_dec("7")), "-2", 20) != 0:
        return 20
    if bi_to_word_checked(bi_from_dec("42")) != 42:
        return 21
    if expect_cmp(bi_mul(bi_from_dec("-123456789"), bi_from_dec("987654321")), "-121932631112635269", 22) != 0:
        return 22
    if expect_cmp(bi_div(bi_from_dec("100"), bi_from_dec("7")), "14", 8) != 0:
        return 8
    if expect_cmp(bi_mod(bi_from_dec("100"), bi_from_dec("7")), "2", 9) != 0:
        return 9
    if expect_cmp(bi_div(bi_from_dec("-7"), bi_from_dec("2")), "-3", 10) != 0:
        return 10
    if expect_cmp(bi_mod(bi_from_dec("-7"), bi_from_dec("2")), "-1", 11) != 0:
        return 11
    if bi_cmp(big, bi_from_dec("1267650600228229401496703205375")) <= 0:
        return 12
    if expect_dec(big, "1267650600228229401496703205376", 13) != 0:
        return 13
    if expect_dec(bi_neg(big), "-1267650600228229401496703205376", 14) != 0:
        return 14
    return 0
