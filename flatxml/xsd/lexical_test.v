module xsd

fn ok(b Builtin, v string) bool {
	return lexical_problem(b, v) == none
}

fn test_numbers() {
	assert ok(.decimal, '-1.5') && ok(.decimal, '+.5') && ok(.decimal, '3.') && !ok(.decimal, '.')
	assert !ok(.decimal, '1e3') && !ok(.decimal, '')
	assert ok(.integer, '-0') && ok(.integer, '+0042') && !ok(.integer, '1.0')
	assert ok(.unsigned_byte, '255') && !ok(.unsigned_byte, '256') && !ok(.unsigned_byte, '-1')
	assert ok(.unsigned_byte, '-0') && ok(.unsigned_byte, '000255')
	assert ok(.long, '-9223372036854775808') && !ok(.long, '9223372036854775808')
	assert ok(.unsigned_long, '18446744073709551615') && !ok(.unsigned_long, '18446744073709551616')
	assert ok(.positive_integer, '1') && !ok(.positive_integer, '0')
	assert ok(.non_positive_integer, '-0') && !ok(.non_positive_integer, '1')
	assert ok(.int, '2147483647') && !ok(.int, '2147483648')
	assert ok(.double, '1.5E-3') && ok(.double, 'INF') && ok(.float, '-INF') && ok(.float, 'NaN')
	assert !ok(.double, '+INF') && !ok(.double, '1E') && !ok(.double, 'E5')
}

fn test_dates_and_times() {
	assert ok(.date_time, '2002-10-10T12:00:00-05:00') && ok(.date_time, '2002-10-10T12:00:00.5Z')
	assert !ok(.date_time, '2002-10-10T25:00:00') && !ok(.date_time, '2002-13-10T12:00:00')
	assert ok(.date, '2000-02-29') && !ok(.date, '1900-02-29') && !ok(.date, '0000-01-01')
	assert ok(.date, '-0001-01-01') && ok(.date, '12345-01-01') && !ok(.date, '01234-01-01')
	assert ok(.time, '24:00:00') && !ok(.time, '24:00:01') && ok(.time, '13:20:00+14:00')
	assert !ok(.time, '13:20:00+14:01') && !ok(.time, '13:20')
	assert ok(.g_year_month, '2001-12') && ok(.g_year, '2001Z') && ok(.g_month_day, '--02-29')
	assert !ok(.g_month_day, '--02-30') && ok(.g_day, '---31') && ok(.g_month, '--12')
	assert !ok(.g_month, '--12--') && !ok(.g_month, '--13')
	assert ok(.duration, 'P1Y2M3DT10H30M') && ok(.duration, '-P120D') && ok(.duration, 'PT1.5S')
	assert !ok(.duration, 'P') && !ok(.duration, 'P1YT') && !ok(.duration, 'P1.5Y')
	assert !ok(.duration, 'P1D1Y') && !ok(.duration, 'PT1H1.5M')
}

fn test_names_and_others() {
	assert ok(.nmtoken, 'a-b.c:d') && !ok(.nmtoken, 'a b') && ok(.nmtokens, 'a b c')
	assert ok(.name, 'x:y') && !ok(.nc_name, 'x:y') && !ok(.name, '1x') && ok(.name, 'éa')
	assert ok(.id, 'id1') && !ok(.id, '1id') && ok(.idrefs, 'a b')
	assert ok(.qname, 'p:x') && !ok(.qname, 'p:') && !ok(.qname, 'a:b:c')
	assert ok(.language, 'en-US') && ok(.language, 'x-123') && !ok(.language, '123')
	assert ok(.boolean, '1') && !ok(.boolean, 'TRUE')
	assert ok(.hex_binary, '0fA9') && !ok(.hex_binary, '0f9') && ok(.hex_binary, '')
	assert ok(.base64_binary, 'AQID') && ok(.base64_binary, 'AQ==') && !ok(.base64_binary, 'AR==')
	assert ok(.base64_binary, 'AQI=') && !ok(.base64_binary, 'AQJ=') && !ok(.base64_binary, 'AQ')
}
