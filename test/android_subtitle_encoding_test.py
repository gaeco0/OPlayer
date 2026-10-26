"""Exercise the actual Android charset helper on a JDK, without an emulator."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
java_home = os.environ.get('JAVA_HOME')
suffix = '.exe' if os.name == 'nt' else ''

def tool(name):
    return str(Path(java_home) / 'bin' / (name + suffix)) if java_home else shutil.which(name)

with tempfile.TemporaryDirectory(prefix='oplayer-subtitle-charset-') as temporary:
    folder = Path(temporary)
    check = folder / 'SubtitleTextCheck.java'
    check.write_text('''
import com.oplayer.oplayer.SubtitleText;
import java.nio.charset.*;
import java.nio.file.*;
import java.util.Arrays;
public class SubtitleTextCheck {
  public static void main(String[] args) throws Exception {
    Path root = Paths.get(args[0]);
    String text = "<SAMI>한국어 뷁 자막</SAMI>";
    String[] encodings = {"UTF-8", "CP949", "UTF-16LE", "UTF-16BE"};
    for (int i = 0; i < encodings.length; i++) {
      String encoding = encodings[i];
      String charset = encoding.equals("CP949") ? "MS949" : encoding;
      String withBom = encoding.equals("CP949") ? text : "\\uFEFF" + text;
      byte[] original = withBom.getBytes(Charset.forName(charset));
      Path input = root.resolve("input" + i + ".smi"), output = root.resolve("output" + i + ".smi");
      Files.write(input, original);
      SubtitleText.toUtf8(input.toString(), output.toString(), encoding);
      if (!text.equals(Files.readString(output, StandardCharsets.UTF_8))) throw new AssertionError(encoding);
      if (!Arrays.equals(original, Files.readAllBytes(input))) throw new AssertionError("Original changed");
    }
    Path invalid = root.resolve("invalid.smi");
    Files.write(invalid, new byte[]{(byte)0xc3, 0x28});
    try {
      SubtitleText.toUtf8(invalid.toString(), root.resolve("bad-output.smi").toString(), "UTF-8");
      throw new AssertionError("Malformed UTF-8 was silently replaced");
    } catch (CharacterCodingException expected) {}
    System.out.println("Android charset helper: CP949 extension Hangul, UTF-8/UTF-16 BOMs, strict errors, originals preserved");
  }
}
''', encoding='utf-8')
    production = root / 'android/app/src/main/java/com/oplayer/oplayer/SubtitleText.java'
    subprocess.run([tool('javac'), '-encoding', 'UTF-8', '-d', temporary, str(production), str(check)], check=True)
    subprocess.run([tool('java'), '-cp', temporary, 'SubtitleTextCheck', temporary], check=True)
