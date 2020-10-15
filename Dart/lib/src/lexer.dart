import 'token.dart';
import 'common.dart';

/// 负责对原始文本进行词法分析并生成Token列表
class Lexer {
  static const _stringReplaces = <String, String>{
    '\\\\': '\\',
    '\\n': '\n',
    '\\\'': '\'',
  };

  static String _convertStringLiteral(String literal) {
    String result = literal.substring(1).substring(0, literal.length - 2);
    for (var key in _stringReplaces.keys) {
      result = result.replaceAll(key, _stringReplaces[key]);
    }
    return result;
  }

  List<Token> lex(String script, {bool commandLine = false}) {
    var _tokens = <Token>[];
    var currentLine = 0;
    var column;
    var pattern = commandLine
        ? RegExp(
            env.lexicon.commandLinePattern,
            unicode: true,
            multiLine: true,
          )
        : RegExp(
            env.lexicon.scriptPattern,
            unicode: true,
            multiLine: true,
          );
    for (var line in script.split('\n')) {
      ++currentLine;
      var matches = pattern.allMatches(line);
      for (var match in matches) {
        var matchString = match.group(0);
        column = match.start + 1;
        if (match.group(env.lexicon.tokenGroupComment) == null) {
          // 标识符
          if (match.group(env.lexicon.tokenGroupIdentifier) != null) {
            if (env.lexicon.keywords.contains(matchString)) {
              _tokens.add(Token(matchString, matchString, currentLine, column));
            } else if (matchString == env.lexicon.TRUE) {
              _tokens.add(TokenBoolLiteral(matchString, true, currentLine, column));
            } else if (matchString == env.lexicon.FALSE) {
              _tokens.add(TokenBoolLiteral(matchString, false, currentLine, column));
            } else {
              _tokens.add(Token(matchString, env.lexicon.identifier, currentLine, column));
            }
          }
          // 标点符号和运算符号
          else if (match.group(env.lexicon.tokenGroupPunctuation) != null) {
            _tokens.add(Token(matchString, matchString, currentLine, column));
          }
          // 数字字面量
          else if (match.group(env.lexicon.tokenGroupNumber) != null) {
            _tokens.add(TokenNumLiteral(matchString, num.parse(matchString), currentLine, column));
          }
          // 字符串字面量
          else if (match.group(env.lexicon.tokenGroupString) != null) {
            var literal = _convertStringLiteral(matchString);
            _tokens.add(TokenStringLiteral(matchString, literal, currentLine, column));
          }
        }
      }
    }
    return _tokens;
  }
}
