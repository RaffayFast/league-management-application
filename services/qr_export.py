"""QR asset exports (Day 2 FR-4.1, spec 5.6): SVG, PNG and a printable PDF poster.

The QR matrix comes from ``segno`` (pure Python). SVG and PNG use segno's writers; the PDF is written here
so the poster can carry the entity id and short link as text next to the vector QR code.
"""
import io

import segno


def _qr(short_url: str):
    return segno.make(short_url, error="m", micro=False)


def svg(short_url: str) -> bytes:
    buf = io.BytesIO()
    _qr(short_url).save(buf, kind="svg", scale=8, border=4, xmldecl=True, title=short_url)
    return buf.getvalue()


def png(short_url: str) -> bytes:
    buf = io.BytesIO()
    _qr(short_url).save(buf, kind="png", scale=8, border=4)
    return buf.getvalue()


def _pdf_text(s: str) -> str:
    return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def pdf(short_url: str, entity_id: str, title: str = "LeagueHub") -> bytes:
    """A4 poster: title, entity id, short link and the QR code drawn as filled squares."""
    matrix = _qr(short_url).matrix
    n = len(matrix)
    module = min(14.0, 360.0 / n)
    size = module * n
    x0, y0 = (595 - size) / 2, 260
    cells = []
    for r, row in enumerate(matrix):
        for c, dark in enumerate(row):
            if dark:
                cells.append(f"{x0 + c * module:.2f} {y0 + (n - 1 - r) * module:.2f} {module:.2f} {module:.2f} re")
    text = (f"BT /F1 28 Tf 60 760 Td ({_pdf_text(title)}) Tj ET "
            f"BT /F1 16 Tf 60 720 Td (Scan to watch: {_pdf_text(entity_id)}) Tj ET "
            f"BT /F1 12 Tf 60 200 Td ({_pdf_text(short_url)}) Tj ET")
    stream = f"0 0 0 rg {' '.join(cells)} f {text}"
    objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        f"<< /Length {len(stream.encode('latin-1', 'replace'))} >>\nstream\n{stream}\nendstream",
    ]
    out = b"%PDF-1.4\n"
    offsets = []
    for i, obj in enumerate(objects, 1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n{obj}\nendobj\n".encode("latin-1", "replace")
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    out += "".join(f"{o:010d} 00000 n \n" for o in offsets).encode()
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return out
