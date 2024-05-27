import 'package:nokufind/src/Subfinder/mangadex_finder.dart';
import 'package:nokufind/src/Utils/mangadex_api.dart';

void main() async {
    MangadexFinder api = MangadexFinder();
    var testPost = api.getPost("c9c0f16b-7bd3-4da6-bd58-fcb4bd10112f");
    testPost.then((value) => print(value));

    //api.searchPosts("genderswap").then((value) => print(value));

    api.postGetChildren((await testPost)!).then((value) => print(value));
}