package service

import (
	"bytes"
	"testing"
)

func TestFileFormatValidation(t *testing.T) {
	for _, mime := range []string{"text/plain", "text/markdown", "text/csv"} {
		if validateFileBytes([]byte("actual body"), mime) != nil {
			t.Fatal(mime)
		}
	}
	for _, c := range []struct {
		data []byte
		mime string
	}{{[]byte("fake"), "application/pdf"}, {[]byte{255}, "text/plain"}, {[]byte("x"), "application/octet-stream"}, {bytes.Repeat([]byte("x"), MaxFileSizeBytes+1), "text/plain"}, {[]byte("not a zip"), "application/vnd.openxmlformats-officedocument.wordprocessingml.document"}} {
		if validateFileBytes(c.data, c.mime) == nil {
			t.Fatal("invalid file accepted", c.mime)
		}
	}
	if isAllowedFileContentType("application/vnd.ms-excel.sheet.macroEnabled.12") {
		t.Fatal("macro workbook accepted")
	}
}
