import 'package:hetu_script/hetu_script.dart';

void main() {
  final hetu = Hetu();
  hetu.init();

  final bytes = hetu.compile('script/program.ht',
      config: CompilerConfig(lineInfo: false));

  print(bytes);
}
