#!/usr/bin/env python3
"""Serve tiny, deterministic PDF/Office preview fixtures on loopback only."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import argparse
import math
import struct
import wave

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=18084)
parser.add_argument('--generate-only', action='store_true')
args = parser.parse_args()
destination = root / 'artifacts/ios-v5-acceptance/preview-files'
destination.mkdir(parents=True, exist_ok=True)

stream = b'BT /F1 24 Tf 55 710 Td (V5 PDF BODY VERIFIED) Tj ET'
objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
           b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
           b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
           b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream']
pdf = bytearray(b'%PDF-1.4\n')
offsets = [0]
for number, obj in enumerate(objects, 1):
    offsets.append(len(pdf))
    pdf.extend(f'{number} 0 obj\n'.encode() + obj + b'\nendobj\n')
xref = len(pdf)
pdf.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
for offset in offsets[1:]:
    pdf.extend(f'{offset:010d} 00000 n \n'.encode())
pdf.extend(f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
(destination / 'layout-check.pdf').write_bytes(pdf)

types = 'http://schemas.openxmlformats.org/package/2006/content-types'
rels = 'http://schemas.openxmlformats.org/package/2006/relationships'
office = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
common = '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
def archive(name, parts):
    with ZipFile(destination / name, 'w', ZIP_DEFLATED) as file:
        for path, content in parts.items():
            file.writestr(path, '<?xml version="1.0" encoding="UTF-8"?>' + content)

archive('layout-check.docx', {
    '[Content_Types].xml': f'<Types xmlns="{types}">{common}<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
    '_rels/.rels': f'<Relationships xmlns="{rels}"><Relationship Id="rId1" Type="{office}/officeDocument" Target="word/document.xml"/></Relationships>',
    'word/document.xml': '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:rPr><w:sz w:val="36"/></w:rPr><w:t>V5 WORD BODY VERIFIED</w:t></w:r></w:p><w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:left="720" w:bottom="1440" w:right="720"/></w:sectPr></w:body></w:document>',
})
archive('layout-check.xlsx', {
    '[Content_Types].xml': f'<Types xmlns="{types}">{common}<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
    '_rels/.rels': f'<Relationships xmlns="{rels}"><Relationship Id="rId1" Type="{office}/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    'xl/workbook.xml': f'<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="{office}"><sheets><sheet name="Preview" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels': f'<Relationships xmlns="{rels}"><Relationship Id="rId1" Type="{office}/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
    'xl/worksheets/sheet1.xml': '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols><col min="1" max="1" width="48" customWidth="1"/></cols><sheetData><row r="1" ht="30" customHeight="1"><c r="A1" t="inlineStr"><is><t>V5 SHEET BODY VERIFIED</t></is></c></row></sheetData></worksheet>',
})
# Real PCM audio for AVPlayer UI checks; these are decoded and played by iOS,
# rather than substituting a synthetic playback state or a header-only file.
for name, seconds, frequency in [('long-a', 90, 220), ('long-b', 90, 330), ('short', 6, 440)]:
    with wave.open(str(destination / f'voice-{name}.wav'), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        second = b''.join(struct.pack('<h', int(1200 * math.sin(2 * math.pi * frequency * i / 16000))) for i in range(16000))
        for _ in range(seconds):
            audio.writeframesraw(second)
(destination / 'voice-invalid.wav').write_bytes(b'not a playable audio file')
print('PDF, Word, spreadsheet and PCM audio fixtures generated.', flush=True)
if not args.generate_only:
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *values, **options):
            super().__init__(*values, directory=str(destination), **options)
        def log_message(self, *_):
            pass
    print(f'Preview fixture ready on 127.0.0.1:{args.port}', flush=True)
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
