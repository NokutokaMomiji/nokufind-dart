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
        List<String> lines = code.split("\n");
        for (String line in lines) {
            if (line.startsWith("var o = ") && line.endsWith(";")) {
                defaultO = int.parse(line.substring(8, line.length - 1));
            }

            if (line.startsWith("o = ") && line.endsWith("; break;")) {
                inCaseO = int.parse(line.substring(4, line.length - 8));
            }

            if (line.startsWith("case ")) {
                String matchedInt = line.substring(5, line.length - 1);
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
        RegExpMatch? match = exp.firstMatch(h);

        if (match == null) {
            throw ArgumentError.value(h, "h", "Invalid hash format.");
        }

        String m2 = match.group(2)!;
        String m1 = match.group(1)!;

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
            hasWebp: jsonData['haswebp'],
            hasAvif: jsonData['hasavif'],
            hasAvifSmallTn: jsonData['hasavifsmalltn'],
        );
    }
}

// Implementation of the Common set of functions from common.js
class Common {
    final GG gg;

    final r = RegExp(r"\/[0-9a-f]{61}([0-9a-f]{2})([0-9a-f])");
    final subdomainReg = RegExp(r"\/\/..?\.hitomi\.la\/");
    final otherReg = RegExp(r"^.*(..)(.)$");
    final tnReg = RegExp(r"//tn\.hitomi\.la/[^/]+/[0-9a-f]/[0-9a-f]{2}/[0-9a-f]{64}");

    Common(String code) : gg = GG(code)..parse();

    String subdomainFromUrl(String url, String urlBase) {
        String returnValue = (urlBase.isEmpty) ? "b" : urlBase;
    
        var m = r.firstMatch(url);

        if (m == null) return "a";

        var g = int.parse(m.group(2)! + m.group(1)!, radix: 16);

        if (!g.isNaN) {
            returnValue = String.fromCharCode(97 + gg.m(g)) + returnValue;
        }

        return returnValue;
    }

    String urlFromUrl(String url, String urlBase) {
        String subdomain = subdomainFromUrl(url, urlBase);

        return url.replaceAll(subdomainReg, "//$subdomain.hitomi.la/");
    }

    String fullPathFromHash(String hash) {
        return "${gg.b}${gg.s(hash)}/$hash";
    }

    String realFullPathFromHash(String hash) {
        return hash.replaceAllMapped(otherReg, 
            (m) => "${m.group(2)}/${m.group(1)}/$hash"
        );
    }

    String urlFromHash(String galleryID, HitomiFile image, String dir, String ext) {
        ext = (ext.isNotEmpty) ? ext : ((dir.isNotEmpty) ? dir : image.name.split(".").last);
        dir = (dir.isNotEmpty) ? dir : "images";

        return "https://a.hitomi.la/$dir/${fullPathFromHash(image.hash)}.$ext";
    }

    String urlFromUrlFromHash(String galleryID, HitomiFile image, String dir, String ext, String urlBase) {
        if (urlBase == "tn") {
            return urlFromUrl("https://a.hitomi.la/$dir/${realFullPathFromHash(image.hash)}.$ext", urlBase);
        }

        return urlFromUrl(urlFromHash(galleryID, image, dir, ext), urlBase);
    }

    String rewriteTnPaths(String html) {
        return html.replaceAllMapped(tnReg, 
            (m) => urlFromUrl(m.group(0)!, "tn")
        );
    }

    String getThumbnail(String galleryID, HitomiFile image) {
        return urlFromUrlFromHash(galleryID, image, "webpbigtn", "webp", "tn");
    }

    List<String> imageUrls(String galleryID, List<HitomiFile> images, {bool preferWebp = true}) {
        return images.map(
            (image) => imageUrlFromImage(galleryID, image, preferWebp: preferWebp)
        ).toList();
    }

    String imageUrlFromImage(String galleryID, HitomiFile image, {bool preferWebp = true}) {
        return urlFromUrlFromHash(galleryID, image, (image.hasAvif == 1 && !preferWebp) ? "avif" : "webp", "", "a");
    }
}