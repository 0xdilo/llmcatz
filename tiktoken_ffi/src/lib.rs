use tiktoken_rs::{get_bpe_from_model, CoreBPE};
use std::ffi::CStr;
use std::sync::Mutex;

static TOKENIZER: Mutex<Option<CoreBPE>> = Mutex::new(None);

#[no_mangle]
pub extern "C" fn tiktoken_init(encoding: *const u8) -> i32 {
    let encoding_str = unsafe {
        if encoding.is_null() {
            return -1;
        }
        CStr::from_ptr(encoding as *const i8).to_str().unwrap_or("cl100k_base")
    };

    let bpe = match encoding_str {
        "o200k_base" => get_bpe_from_model("gpt-4o").ok(),
        "cl100k_base" => get_bpe_from_model("gpt-3.5-turbo").ok(),
        "p50k_base" => get_bpe_from_model("text-davinci-003").ok(),
        "p50k_edit" => get_bpe_from_model("text-davinci-edit-001").ok(),
        "r50k_base" => get_bpe_from_model("gpt2").ok(),
        _ => return -2,
    };

    match TOKENIZER.lock() {
        Ok(mut tokenizer) => {
            *tokenizer = bpe;
            if tokenizer.is_none() {
                return -4;
            }
            0
        }
        Err(_) => -3, 
    }
}

#[no_mangle]
pub extern "C" fn tiktoken_count(text: *const u8) -> usize {
    let text_str = unsafe {
        if text.is_null() {
            return 0;
        }
        CStr::from_ptr(text as *const i8).to_str().unwrap_or("")
    };

    match TOKENIZER.lock() {
        Ok(tokenizer) => match *tokenizer {
            Some(ref bpe) => bpe.encode_with_special_tokens(text_str).len(),
            None => 0, 
        },
        Err(_) => 0, 
    }
}

#[no_mangle]
pub extern "C" fn tiktoken_cleanup() {
    if let Ok(mut tokenizer) = TOKENIZER.lock() {
        *tokenizer = None;
    }
}
