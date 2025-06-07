// Code adapted and derived from Heliotrope
// https://github.com/Saebasol/Heliotrope
// Huge thanks to the relevant parties because this is a nightmare.


// Implementation of the GG functions.
class GG {
    final RegExp exp = RegExp(r"(..)(.)$");

    String code;
    List<int> caseList = [];
    int defaultO = 0;
    int inCaseO = 0;
    String b = "";

    GG(this.code);

    void parse() {
        final List<String> lines = code.split("\n");
        for (final String line in lines) {
            if (line.startsWith("var o = ") && line.endsWith(";")) {
                defaultO = int.parse(line.substring(8, line.length - 1));
            }

            if (line.startsWith("o = ") && line.endsWith("; break;")) {
                inCaseO = int.parse(line.substring(4, line.length - 8));
            }

            if (line.startsWith("case ")) {
                final String matchedInt = line.substring(5, line.length - 1);
                caseList.add(int.parse(matchedInt));
            }

            if (line.startsWith("b: ")) {
                b = line.substring(4, line.length - 1);
            }
        }
    }

    void refresh(String code) {
        this.code = code;
        caseList.clear();
        parse();
    }

    int m(int g) {
        if (caseList.contains(g)) {
            return inCaseO;
        }

        return defaultO;
    }

    String s(String h) {
        final RegExpMatch? match = exp.firstMatch(h);

        if (match == null) {
            throw ArgumentError.value(h, "h", "Invalid hash format.");
        }

        final String m2 = match.group(2)!;
        final String m1 = match.group(1)!;

        return BigInt.parse(m2 + m1, radix: 16).toString();
    }
}

class HitomiFile {
    final int galleryInfoID;
    final String name;
    final int width;
    final int height;
    final String hash;
    final int hasWebp;
    final int hasAvif;
    final int? hasAvifSmallTn;

    HitomiFile({
        required this.galleryInfoID,
        required this.name,
        required this.width,
        required this.height,
        required this.hash,
        required this.hasWebp,
        required this.hasAvif,
        this.hasAvifSmallTn,
    });

    factory HitomiFile.fromJson(int galleryInfoID, Map<String, dynamic> jsonData) {
        return HitomiFile(
            galleryInfoID: galleryInfoID,
            name: jsonData['name'],
            width: jsonData['width'],
            height: jsonData['height'],
            hash: jsonData['hash'],
            hasWebp: jsonData['haswebp'] ?? 1,
            hasAvif: jsonData['hasavif'],
            hasAvifSmallTn: jsonData['hasavifsmalltn'],
        );
    }
}

// Implementation of the Common set of functions from common.js
class Common {
  final GG gg;
  static const String domain = "gold-usergeneratedcontent.net";

  // Use normal string literals (with escaping) to allow variable concatenation.
  final RegExp r = RegExp(r"/[0-9a-f]{61}([0-9a-f]{2})([0-9a-f])");
  final RegExp subdomainReg =
      RegExp(r"//..?\.(?:gold-usergeneratedcontent\.net|hitomi\.la)/");
  final RegExp otherReg = RegExp(r"^.*(..)(.)$");
  final RegExp tnReg = RegExp(r"//tn\\." + domain + r"\\.la/[^/]+/[0-9a-f]/[0-9a-f]{2}/[0-9a-f]{64}");

  Common(String code) : gg = GG(code)..parse();

  String subdomainFromUrl(String url, String urlBase) {
    // If no base provided, default to "b" (or later, a numeric value will be appended).
    String returnValue = urlBase.isEmpty ? "b" : urlBase;

    final m = r.firstMatch(url);
    if (m == null) return "a";

    // Concatenate captured groups (order reversed compared to the RegExp)
    final g = int.parse(m.group(2)! + m.group(1)!, radix: 16);

    // In JavaScript, the check is if (!isNaN(g)) but in Dart the int parse always returns an int.
    if (urlBase.isNotEmpty) {
      returnValue = String.fromCharCode(97 + gg.m(g)) + urlBase;
    } else {
      // When no base is provided, append (1 + gg.m(g)) to the default.
      returnValue = (1 + gg.m(g)).toString();
    }
    return returnValue;
  }

  String urlFromUrl(String url, String urlBase) {
    final String subdomain = subdomainFromUrl(url, urlBase);
    // Replace the matched subdomain part with the new subdomain and our fixed domain.
    return url.replaceAll(subdomainReg, "//$subdomain.$domain/");
  }

  String fullPathFromHash(String hash) {
    return "${gg.b}${gg.s(hash)}/$hash";
  }

  String realFullPathFromHash(String hash) {
    return hash.replaceAllMapped(otherReg,
        (m) => "${m.group(2)}/${m.group(1)}/$hash");
  }

  String urlFromHash(String galleryID, HitomiFile image, String dir, String ext) {
    // Determine the extension (if ext is empty, then use dir if not empty; otherwise, use file extension).
    ext = ext.isNotEmpty ? ext : (dir.isNotEmpty ? dir : image.name.split(".").last);
    // Mimic the JS behavior: for "webp" or "avif", set dir to empty; otherwise add a trailing slash.
    if (dir == "webp" || dir == "avif") {
      dir = "";
    } else if (dir.isNotEmpty) {
      dir = "$dir/";
    }
    // Note: The original JS uses the subdomain "a.", so we use that here.
    return "https://a.$domain/$dir${fullPathFromHash(image.hash)}.$ext";
  }

  String urlFromUrlFromHash(String galleryID, HitomiFile image, String dir, String ext, String urlBase) {
    if (urlBase == "tn") {
      // For thumbnail URLs, use the real_full_path logic.
      return urlFromUrl("https://a.$domain/$dir/${realFullPathFromHash(image.hash)}.$ext", urlBase);
    }
    return urlFromUrl(urlFromHash(galleryID, image, dir, ext), urlBase);
  }

  String rewriteTnPaths(String html) {
    // Replace matching tn URLs using our urlFromUrl function.
    return html.replaceAllMapped(tnReg, (m) => urlFromUrl(m.group(0)!, "tn"));
  }

  String getThumbnail(String galleryID, HitomiFile image) {
    return urlFromUrlFromHash(galleryID, image, "webpbigtn", "webp", "tn");
  }

  List<String> imageUrls(String galleryID, List<HitomiFile> images, {bool preferWebp = true}) {
    return images
        .map((image) => imageUrlFromImage(galleryID, image, preferWebp: preferWebp))
        .toList();
  }

  String imageUrlFromImage(String galleryID, HitomiFile image, {bool preferWebp = true}) {
    // Choose "avif" if available and not preferring webp; otherwise "webp".
    final String chosenDir = (image.hasAvif == 1 && !preferWebp) ? "avif" : "webp";
    return urlFromUrlFromHash(galleryID, image, chosenDir, "", "a").replaceAll("aa", "a1").replaceAll("ba", "a1");
  }
}
