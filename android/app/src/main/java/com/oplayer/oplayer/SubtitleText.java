package com.oplayer.oplayer;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.charset.Charset;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

/** Charset conversion is independent of the optional iconv support in libmpv/FFmpeg. */
public final class SubtitleText {
    public static void toUtf8(String input, String output, String encoding) throws Exception {
        String charset = encoding.equalsIgnoreCase("CP949") ? "MS949" : encoding;
        java.nio.charset.CharsetDecoder decoder = Charset.forName(charset).newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT);
        try (InputStreamReader reader = new InputStreamReader(new FileInputStream(input), decoder);
             OutputStreamWriter writer = new OutputStreamWriter(new FileOutputStream(output), StandardCharsets.UTF_8)) {
            int first = reader.read();
            if (first != -1 && first != '\uFEFF') writer.write(first);
            char[] buffer = new char[8192];
            int count;
            while ((count = reader.read(buffer)) != -1) writer.write(buffer, 0, count);
        }
    }
}
