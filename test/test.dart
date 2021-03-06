import 'package:hetu_script/hetu_script.dart';

void main() {
  // final parser = HTAstParser();
  // final nodes = parser.parseString('');
  // print(nodes);

  // final lexer = HTLexer();
  // final tokens = lexer.lex('');
  // print(tokens);

  final source = HTSource(r'''
        enum Race {
          caucasian,
          mongolian,
          african,
        }
        var race: Race = Race.african
        print( race.toString())
  ''', type: SourceType.script);
  // // final parser = HTAstParser();
  // final module = parser.parseToModule(source);
  // final formatter = HTFormatter();
  // formatter.formatModule(module);
  // print('${module.fullName}');
  // print('--------------------------------------------------------------------');
  // print(module.source.content);

  final hetu = Hetu();
  hetu.init();
  hetu.evalSource(source);
}
