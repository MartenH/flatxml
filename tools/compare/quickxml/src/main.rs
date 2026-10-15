use quick_xml::events::Event;
use quick_xml::reader::Reader;
use std::time::Instant;

fn main() {
    let path = std::env::args().nth(1).expect("usage: qx <file>");
    let data = std::fs::read(&path).unwrap();
    let t = Instant::now();
    // borrowed events from the slice: no copy of the input
    let mut r = Reader::from_reader(&data[..]);
    r.config_mut().check_end_names = true;
    let (mut elems, mut attrs, mut texts) = (0u64, 0u64, 0u64);
    // every event, and every attribute of every start tag (checked for duplicates and syntax)
    loop {
        match r.read_event() {
            Ok(Event::Start(e)) | Ok(Event::Empty(e)) => {
                elems += 1;
                for a in e.attributes() {
                    a.unwrap();
                    attrs += 1;
                }
            }
            Ok(Event::Text(_)) | Ok(Event::CData(_)) => texts += 1,
            Ok(Event::Eof) => break,
            Err(e) => panic!("{e}"),
            _ => {}
        }
    }
    let s = t.elapsed().as_secs_f64();
    println!("quick-xml: {:.1} ms, {:.0} MB/s, {} elements, {} attributes, {} text events",
             s * 1e3, data.len() as f64 / 1048576.0 / s, elems, attrs, texts);
}
