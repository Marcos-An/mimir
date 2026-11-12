//! Runs shared/fixtures, the same files the Mac app's SharedFixtureTests run.

use mimir_core::{anthropic, cleaner, utf16::Range16, writing::checker, writing::model};
use serde_json::Value;

fn fixture(name: &str) -> Value {
    let path = format!("{}/../../shared/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&std::fs::read_to_string(&path).expect(&path)).unwrap()
}

fn cases<'a>(file: &'a Value, key: &str) -> &'a Vec<Value> {
    file[key].as_array().unwrap_or_else(|| panic!("missing {key}"))
}

fn s(v: &Value) -> String {
    v.as_str().unwrap_or_default().to_string()
}

fn finding(item: &Value) -> model::Finding {
    model::Finding {
        sentence: s(&item["sentence"]),
        original: s(&item["original"]),
        replacement: s(&item["replacement"]),
        why: item["why"].as_str().unwrap_or("x").to_string(),
        kind: serde_json::from_value(item.get("kind").cloned().unwrap_or("grammar".into())).unwrap(),
    }
}

#[test]
fn cleaner_fixtures() {
    let file = fixture("cleaner.json");
    for item in cases(&file, "clean") {
        assert_eq!(cleaner::clean(&s(&item["in"])), s(&item["out"]), "clean({:?})", item["in"]);
    }
    for item in cases(&file, "midTextFarewells") {
        assert_eq!(cleaner::strip_mid_text_farewells(&s(&item["in"])), s(&item["out"]), "mid({:?})", item["in"]);
    }
}

#[test]
fn writing_fixtures() {
    let file = fixture("writing.json");
    for item in cases(&file, "sentences") {
        let actual: Vec<(String, usize, usize, bool)> = model::sentences(&s(&item["text"]))
            .into_iter()
            .map(|x| (x.text, x.range.location, x.range.length, x.is_complete))
            .collect();
        let expected: Vec<(String, usize, usize, bool)> = item["sentences"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| (s(&row[0]), row[1].as_u64().unwrap() as usize, row[2].as_u64().unwrap() as usize, row[3].as_bool().unwrap()))
            .collect();
        assert_eq!(actual, expected, "sentences({:?})", item["text"]);
    }
    for item in cases(&file, "acceptable") {
        assert_eq!(checker::is_acceptable(&finding(item)), item["ok"].as_bool().unwrap(), "acceptable {item}");
    }
    for item in cases(&file, "parse") {
        let checked: Vec<String> = item["checked"].as_array().unwrap().iter().map(s).collect();
        let expected: Vec<model::Finding> = item["findings"].as_array().unwrap().iter().map(finding).collect();
        assert_eq!(checker::parse(&s(&item["reply"]), &checked), expected, "parse {}", item["reply"]);
    }
    for item in cases(&file, "anchor") {
        let expected = item["range"].as_array().map(|r| Range16 {
            location: r[0].as_u64().unwrap() as usize,
            length: r[1].as_u64().unwrap() as usize,
        });
        assert_eq!(model::anchor(&finding(item), &s(&item["text"])), expected, "anchor {}", item["text"]);
    }
    for item in cases(&file, "apply") {
        let applied = model::applying(&finding(item), &s(&item["text"])).map(|(text, _)| text);
        assert_eq!(applied, item["result"].as_str().map(str::to_string));
    }
    for item in cases(&file, "touchesVocabulary") {
        let vocabulary: Vec<String> = item["vocabulary"].as_array().unwrap().iter().map(s).collect();
        assert_eq!(checker::touches_vocabulary(&finding(item), &vocabulary), item["touches"].as_bool().unwrap(), "vocabulary {item}");
    }
}

#[test]
fn anthropic_fixtures() {
    let file = fixture("anthropic.json");
    for item in cases(&file, "outOfCredits") {
        let status = item["status"].as_u64().unwrap() as u16;
        assert_eq!(anthropic::is_out_of_credits(status, s(&item["body"]).as_bytes()), item["out"].as_bool().unwrap(), "{item}");
    }
}
