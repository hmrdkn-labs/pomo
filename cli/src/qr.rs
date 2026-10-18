//! Terminal QR codes drawn with unicode half blocks.

use qrcode::render::unicode::Dense1x2;
use qrcode::QrCode;

/// Renders `text` as a QR code, two module rows per text line, with a quiet zone. Modules are
/// drawn light on the terminal's dark background, which phone cameras read.
pub fn render(text: &str) -> Result<String, String> {
    let code = QrCode::new(text.as_bytes()).map_err(|e| format!("cannot encode QR code: {e}"))?;
    Ok(code.render::<Dense1x2>().dark_color(Dense1x2::Light).light_color(Dense1x2::Dark).quiet_zone(true).build())
}

#[cfg(test)]
mod tests {
    use super::render;

    #[test]
    fn renders_half_blocks_for_a_ticket_sized_payload() {
        let text = format!("pomo-pair:{}", "a".repeat(400));
        let qr = render(&text).unwrap();
        assert!(qr.lines().count() > 20);
        assert!(qr.chars().all(|c| matches!(c, ' ' | '\n' | '▀' | '▄' | '█')));
    }
}
