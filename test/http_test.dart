
import 'package:dio/dio.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:nokufind/nokufind.dart';
import 'package:nokufind/src/Subfinder/nhentai_finder.dart';
import 'package:http/http.dart';

String test = "iH4Nt3PGgLVOjadY9L.j3et8lIpYVoZoSEF5ip5r8FM-1714511517-1.0.1.1-I7GR.o5ELhzpyEJjPvYqDi0rey8GSb.76xpFAqWV7qrXhSUpaDxHIP0XmMy4v2F92b.ktDunWrZvhKMjMAIINg";

void main() async {
    DanbooruFinder client = DanbooruFinder();

    //client.searchPosts("hololive", limit: 2, page: 2).then((value) => print("hololive: \n$value"));

    var u = "https://cdn.donmai.us/original/b8/b9/b8b9e8e9053fc4de41b917aebdb4e5f3.jpg";
    Dio _client = Dio();

    var a = await _client.get(u);
    print(a.headers);
    print(a.requestOptions.headers);

    _client.httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: Duration(seconds: 15)), fallbackAdapter: HttpClientAdapter());

    a = await _client.get(u);
    print(a.headers);
    print(a.requestOptions.headers);
    //client.getPost(9638032).then((value) => print("9638032: $value"));

    //client.searchComments(postID: null).then((value) => print(value));

    //client.searchComments(postID: 9772163).then((value) => print(value));

    //client.getNotes(9638032).then((value) => print(value));

    //client.searchPosts("mind control english").then((value) => print(value));

    //client.getPost(505568).then((value) => print(value));
    
    //client.searchComments().then((value) => print(value));
}