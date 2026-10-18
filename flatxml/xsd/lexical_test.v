module xsd

fn accepts(b Builtin, v string) bool {
	return lexical_problem(b, v) == none
}

fn test_numbers() {
	assert accepts(.decimal, '-1.5') && accepts(.decimal, '+.5') && accepts(.decimal, '3.') && !accepts(.decimal, '.')
	assert !accepts(.decimal, '1e3') && !accepts(.decimal, '')
	assert accepts(.integer, '-0') && accepts(.integer, '+0042') && !accepts(.integer, '1.0')
	assert accepts(.unsigned_byte, '255') && !accepts(.unsigned_byte, '256') && !accepts(.unsigned_byte, '-1')
	assert accepts(.unsigned_byte, '-0') && accepts(.unsigned_byte, '000255')
	assert accepts(.long, '-9223372036854775808') && !accepts(.long, '9223372036854775808')
	assert accepts(.unsigned_long, '18446744073709551615') && !accepts(.unsigned_long, '18446744073709551616')
	assert accepts(.positive_integer, '1') && !accepts(.positive_integer, '0')
	assert accepts(.non_positive_integer, '-0') && !accepts(.non_positive_integer, '1')
	assert accepts(.int, '2147483647') && !accepts(.int, '2147483648')
	assert accepts(.double, '1.5E-3') && accepts(.double, 'INF') && accepts(.float, '-INF') && accepts(.float, 'NaN')
	assert !accepts(.double, '+INF') && !accepts(.double, '1E') && !accepts(.double, 'E5')
}

fn test_dates_and_times() {
	assert accepts(.date_time, '2002-10-10T12:00:00-05:00') && accepts(.date_time, '2002-10-10T12:00:00.5Z')
	assert !accepts(.date_time, '2002-10-10T25:00:00') && !accepts(.date_time, '2002-13-10T12:00:00')
	assert accepts(.date, '2000-02-29') && !accepts(.date, '1900-02-29') && !accepts(.date, '0000-01-01')
	assert accepts(.date, '-0001-01-01') && accepts(.date, '12345-01-01') && !accepts(.date, '01234-01-01')
	assert accepts(.time, '24:00:00') && !accepts(.time, '24:00:01') && accepts(.time, '13:20:00+14:00')
	assert !accepts(.time, '13:20:00+14:01') && !accepts(.time, '13:20')
	assert accepts(.g_year_month, '2001-12') && accepts(.g_year, '2001Z') && accepts(.g_month_day, '--02-29')
	assert !accepts(.g_month_day, '--02-30') && accepts(.g_day, '---31') && accepts(.g_month, '--12')
	assert !accepts(.g_month, '--12--') && !accepts(.g_month, '--13')
	assert accepts(.duration, 'P1Y2M3DT10H30M') && accepts(.duration, '-P120D') && accepts(.duration, 'PT1.5S')
	assert !accepts(.duration, 'P') && !accepts(.duration, 'P1YT') && !accepts(.duration, 'P1.5Y')
	assert !accepts(.duration, 'P1D1Y') && !accepts(.duration, 'PT1H1.5M')
}

fn test_names_and_others() {
	assert accepts(.nmtoken, 'a-b.c:d') && !accepts(.nmtoken, 'a b') && accepts(.nmtokens, 'a b c')
	assert accepts(.name, 'x:y') && !accepts(.nc_name, 'x:y') && !accepts(.name, '1x') && accepts(.name, 'éa')
	assert accepts(.id, 'id1') && !accepts(.id, '1id') && accepts(.idrefs, 'a b')
	assert accepts(.qname, 'p:x') && !accepts(.qname, 'p:') && !accepts(.qname, 'a:b:c')
	assert accepts(.language, 'en-US') && accepts(.language, 'x-123') && !accepts(.language, '123')
	assert accepts(.boolean, '1') && !accepts(.boolean, 'TRUE')
	assert accepts(.hex_binary, '0fA9') && !accepts(.hex_binary, '0f9') && accepts(.hex_binary, '')
	assert accepts(.base64_binary, 'AQID') && accepts(.base64_binary, 'AQ==') && !accepts(.base64_binary, 'AR==')
	assert accepts(.base64_binary, 'AQI=') && !accepts(.base64_binary, 'AQJ=') && !accepts(.base64_binary, 'AQ')
}
