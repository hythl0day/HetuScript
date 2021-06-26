import '../grammar/lexicon.dart';
import '../grammar/token.dart';
import '../grammar/semantic.dart';
import '../source/source_provider.dart';
import '../source/source.dart';
import '../declaration/class/class_declaration.dart';
import '../error/error.dart';
import '../ast/ast.dart';
import '../ast/ast_compilation.dart';
import '../error/error_handler.dart';
import 'abstract_parser.dart';
import 'lexer.dart';

class HTAstParser extends AbstractParser {
  final _curModuleImports = <ImportStmt>[];

  late String _curModuleFullName;
  @override
  String get curModuleFullName => _curModuleFullName;

  late String _curLibraryName;
  @override
  String get curLibraryName => _curLibraryName;

  HTClassDeclaration? _curClass;
  FunctionCategory? _curFuncCategory;

  var _leftValueLegality = false;
  final List<Map<String, String>> _markedSymbolsList = [];

  bool _isLibrary = false;

  late HTSource _curSource;

  HTAstParser(
      {ParserConfig config = const ParserConfigImpl(),
      HTErrorHandler? errorHandler,
      HTSourceProvider? sourceProvider})
      : super(
            config: config,
            errorHandler: errorHandler,
            sourceProvider: sourceProvider);

  List<AstNode> parse(List<Token> tokens, HTSource source,
      {ParserConfig? config}) {
    _curSource = source;
    _curModuleFullName = source.fullName;
    final savedConfig = this.config;
    if (config != null) {
      this.config = config;
    }
    addTokens(tokens);
    final nodes = <AstNode>[];
    while (curTok.type != SemanticNames.endOfFile) {
      if (curTok.type == SemanticNames.emptyLine) {
        advance(1);
      } else {
        final stmt = _parseStmt(sourceType: this.config.sourceType);
        nodes.add(stmt);
      }
    }
    this.config = savedConfig;
    return nodes;
  }

  HTAstModule parseToModule(HTSource source,
      {bool hasOwnNamespace = true, ParserConfig? config}) {
    _curModuleFullName = source.fullName;
    _curClass = null;
    _curFuncCategory = null;
    final tokens = HTLexer().lex(source.content);
    final nodes = parse(tokens, source, config: config);
    final module = HTAstModule(source, nodes, this.config.sourceType,
        imports: _curModuleImports.toList(), // copy the list
        hasOwnNamespace: hasOwnNamespace,
        isLibrary: _isLibrary);
    _curModuleImports.clear();
    return module;
  }

  /// Parse a string content and generate a library,
  /// will import other files.
  HTAstCompilation parseToCompilation(HTSource source,
      {bool hasOwnNamespace = true, ParserConfig? config}) {
    _curLibraryName = source.libraryName;
    final module =
        parseToModule(source, hasOwnNamespace: hasOwnNamespace, config: config);
    final compilation = HTAstCompilation();
    for (final stmt in module.imports) {
      final importFullName =
          sourceProvider.resolveFullName(stmt.key, module.fullName);
      if (!sourceProvider.hasModule(importFullName)) {
        final source2 = sourceProvider.getSourceSync(importFullName,
            from: _curModuleFullName,
            errorType: ErrorType.syntacticError,
            line: stmt.line,
            column: stmt.column);
        if (source2 == null) {
          continue;
        }
        final compilation2 = parseToCompilation(source2,
            config: ParserConfigImpl(sourceType: SourceType.module));
        _curModuleFullName = source.fullName;
        compilation.join(compilation2);
      }
    }
    compilation.add(module);
    return compilation;
  }

  AstNode _parseStmt({SourceType sourceType = SourceType.function}) {
    switch (sourceType) {
      case SourceType.script:
        if (curTok.lexeme == HTLexicon.IMPORT) {
          return _parseImportStmt();
        } else if (curTok.lexeme == HTLexicon.TYPE) {
          return _parseTypeAliasDecl();
        } else {
          switch (curTok.type) {
            case SemanticNames.singleLineComment:
            case SemanticNames.multiLineComment:
              return _parseExprStmt();
            case HTLexicon.EXPORT:
              advance(1);
              switch (curTok.type) {
                case HTLexicon.ABSTRACT:
                  advance(1);
                  return _parseClassDecl(
                      isAbstract: true,
                      isExternal: true,
                      isExported: true,
                      isTopLevel: true);
                case HTLexicon.CLASS:
                  return _parseClassDecl(
                      isExternal: true, isExported: true, isTopLevel: true);
                case HTLexicon.ENUM:
                  return _parseEnumDecl(
                      isExternal: true, isExported: true, isTopLevel: true);
                case HTLexicon.VAR:
                  return _parseVarDecl(
                      isMutable: true, isExported: true, isTopLevel: true);
                case HTLexicon.LET:
                  return _parseVarDecl(
                      typeInferrence: true,
                      isMutable: true,
                      isExported: true,
                      isTopLevel: true);
                case HTLexicon.FINAL:
                  return _parseVarDecl(
                      typeInferrence: true, isExported: true, isTopLevel: true);
                case HTLexicon.FUNCTION:
                  return _parseFuncDecl(
                      isExternal: true, isExported: true, isTopLevel: true);
                default:
                  final err = HTError.unexpected(
                      SemanticNames.declStmt, curTok.lexeme,
                      moduleFullName: _curModuleFullName,
                      line: curTok.line,
                      column: curTok.column);
                  errorHandler.handleError(err);
                  final errToken = advance(1);
                  return EmptyExpr(errToken.line, errToken.column);
              }
            case HTLexicon.EXTERNAL:
              advance(1);
              switch (curTok.type) {
                case HTLexicon.ABSTRACT:
                  advance(1);
                  return _parseClassDecl(
                      isAbstract: true, isExternal: true, isTopLevel: true);
                case HTLexicon.CLASS:
                  return _parseClassDecl(isExternal: true, isTopLevel: true);
                case HTLexicon.ENUM:
                  return _parseEnumDecl(isExternal: true, isTopLevel: true);
                case HTLexicon.VAR:
                case HTLexicon.LET:
                case HTLexicon.FINAL:
                  final err = HTError.externalVar(
                      moduleFullName: _curModuleFullName,
                      line: curTok.line,
                      column: curTok.column);
                  errorHandler.handleError(err);
                  final errToken = advance(1);
                  return EmptyExpr(errToken.line, errToken.column);
                case HTLexicon.FUNCTION:
                  return _parseFuncDecl(isExternal: true, isTopLevel: true);
                default:
                  final err = HTError.unexpected(
                      SemanticNames.declStmt, curTok.lexeme,
                      moduleFullName: _curModuleFullName,
                      line: curTok.line,
                      column: curTok.column);
                  errorHandler.handleError(err);
                  final errToken = advance(1);
                  return EmptyExpr(errToken.line, errToken.column);
              }
            case HTLexicon.ABSTRACT:
              advance(1);
              return _parseClassDecl(isAbstract: true, isTopLevel: true);
            case HTLexicon.ENUM:
              return _parseEnumDecl(isTopLevel: true);
            case HTLexicon.CLASS:
              return _parseClassDecl(isTopLevel: true);
            case HTLexicon.VAR:
              return _parseVarDecl(isMutable: true, isTopLevel: true);
            case HTLexicon.LET:
              return _parseVarDecl(
                  typeInferrence: true, isMutable: true, isTopLevel: true);
            case HTLexicon.FINAL:
              return _parseVarDecl(typeInferrence: true, isTopLevel: true);
            case HTLexicon.FUNCTION:
              if (expect([HTLexicon.FUNCTION, SemanticNames.identifier]) ||
                  expect([
                    HTLexicon.FUNCTION,
                    HTLexicon.squareLeft,
                    SemanticNames.identifier,
                    HTLexicon.squareRight,
                    SemanticNames.identifier
                  ])) {
                return _parseFuncDecl(isTopLevel: true);
              } else {
                return _parseFuncDecl(
                    category: FunctionCategory.literal, isTopLevel: true);
              }
            case HTLexicon.IF:
              return _parseIfStmt();
            case HTLexicon.WHILE:
              return _parseWhileStmt();
            case HTLexicon.DO:
              return _parseDoStmt();
            case HTLexicon.FOR:
              return _parseForStmt();
            case HTLexicon.WHEN:
              return _parseWhenStmt();
            default:
              return _parseExprStmt();
          }
        }
      case SourceType.module:
        if (curTok.lexeme == HTLexicon.LIBRARY) {
          return _parseLibraryStmt();
        } else if (curTok.lexeme == HTLexicon.IMPORT) {
          return _parseImportStmt();
        } else if (curTok.lexeme == HTLexicon.TYPE) {
          return _parseTypeAliasDecl();
        } else {
          switch (curTok.type) {
            case SemanticNames.singleLineComment:
            case SemanticNames.multiLineComment:
              return _parseExprStmt();
            case HTLexicon.EXPORT:
              advance(1);
              switch (curTok.type) {
                case HTLexicon.ABSTRACT:
                  advance(1);
                  return _parseClassDecl(
                      isAbstract: true, isExternal: true, isExported: true);
                case HTLexicon.CLASS:
                  return _parseClassDecl(isExternal: true, isExported: true);
                case HTLexicon.ENUM:
                  return _parseEnumDecl(isExternal: true, isExported: true);
                case HTLexicon.VAR:
                  return _parseVarDecl(isMutable: true, isExported: true);
                case HTLexicon.LET:
                  return _parseVarDecl(
                      typeInferrence: true, isMutable: true, isExported: true);
                case HTLexicon.FINAL:
                  return _parseVarDecl(typeInferrence: true, isExported: true);
                case HTLexicon.FUNCTION:
                  return _parseFuncDecl(isExternal: true, isExported: true);
                default:
                  final err = HTError.unexpected(
                      SemanticNames.declStmt, curTok.lexeme,
                      moduleFullName: _curModuleFullName,
                      line: curTok.line,
                      column: curTok.column);
                  errorHandler.handleError(err);
                  final errToken = advance(1);
                  return EmptyExpr(errToken.line, errToken.column);
              }
            case HTLexicon.EXTERNAL:
              advance(1);
              switch (curTok.type) {
                case HTLexicon.ABSTRACT:
                  advance(1);
                  if (curTok.type != HTLexicon.CLASS) {
                    final err = HTError.unexpected(
                        SemanticNames.classDeclaration, curTok.lexeme,
                        moduleFullName: _curModuleFullName,
                        line: curTok.line,
                        column: curTok.column);
                    errorHandler.handleError(err);
                    final errToken = advance(1);
                    return EmptyExpr(errToken.line, errToken.column);
                  }
                  return _parseClassDecl(isAbstract: true, isExternal: true);
                case HTLexicon.CLASS:
                  return _parseClassDecl(isExternal: true);
                case HTLexicon.ENUM:
                  return _parseEnumDecl(isExternal: true);
                case HTLexicon.FUNCTION:
                  if (!expect([HTLexicon.FUNCTION, SemanticNames.identifier])) {
                    final err = HTError.unexpected(
                        SemanticNames.functionDeclaration, peek(1).lexeme,
                        moduleFullName: _curModuleFullName,
                        line: curTok.line,
                        column: curTok.column);
                    errorHandler.handleError(err);
                    final errToken = advance(1);
                    return EmptyExpr(errToken.line, errToken.column);
                  }
                  return _parseFuncDecl(isExternal: true);
                case HTLexicon.VAR:
                case HTLexicon.LET:
                case HTLexicon.FINAL:
                  final err = HTError.externalVar(
                      moduleFullName: _curModuleFullName,
                      line: curTok.line,
                      column: curTok.column);
                  errorHandler.handleError(err);
                  final errToken = advance(1);
                  return EmptyExpr(errToken.line, errToken.column);
                default:
                  final err = HTError.unexpected(
                      SemanticNames.declStmt, curTok.lexeme,
                      moduleFullName: _curModuleFullName,
                      line: curTok.line,
                      column: curTok.column);
                  errorHandler.handleError(err);
                  final errToken = advance(1);
                  return EmptyExpr(errToken.line, errToken.column);
              }
            case HTLexicon.ABSTRACT:
              advance(1);
              return _parseClassDecl(isAbstract: true);
            case HTLexicon.ENUM:
              return _parseEnumDecl();
            case HTLexicon.CLASS:
              return _parseClassDecl();
            case HTLexicon.VAR:
              return _parseVarDecl(isMutable: true, lateInitialize: true);
            case HTLexicon.LET:
              return _parseVarDecl(typeInferrence: true, lateInitialize: true);
            case HTLexicon.FINAL:
              return _parseVarDecl(typeInferrence: true, lateInitialize: true);
            case HTLexicon.FUNCTION:
              return _parseFuncDecl();
            default:
              final err = HTError.unexpected(
                  SemanticNames.declStmt, curTok.lexeme,
                  moduleFullName: _curModuleFullName,
                  line: curTok.line,
                  column: curTok.column);
              errorHandler.handleError(err);
              final errToken = advance(1);
              return EmptyExpr(errToken.line, errToken.column);
          }
        }
      case SourceType.klass:
        final isOverrided = expect([HTLexicon.OVERRIDE], consume: true);
        final isExternal = expect([HTLexicon.EXTERNAL], consume: true) ||
            (_curClass?.isExternal ?? false);
        final isStatic = expect([HTLexicon.STATIC], consume: true);
        if (curTok.lexeme == HTLexicon.TYPE) {
          if (isExternal) {
            final err = HTError.externalType(
                moduleFullName: _curModuleFullName,
                line: curTok.line,
                column: curTok.column);
            errorHandler.handleError(err);
            final errToken = advance(1);
            return EmptyExpr(errToken.line, errToken.column);
          }
          return _parseTypeAliasDecl();
        } else {
          switch (curTok.type) {
            case SemanticNames.singleLineComment:
            case SemanticNames.multiLineComment:
              return _parseExprStmt();
            case HTLexicon.VAR:
              return _parseVarDecl(
                  classId: _curClass?.id,
                  isOverrided: isOverrided,
                  isExternal: isExternal,
                  isMutable: true,
                  isStatic: isStatic,
                  lateInitialize: true);
            case HTLexicon.LET:
              return _parseVarDecl(
                  classId: _curClass?.id,
                  typeInferrence: true,
                  isOverrided: isOverrided,
                  isExternal: isExternal,
                  isMutable: true,
                  isStatic: isStatic,
                  lateInitialize: true);
            case HTLexicon.FINAL:
              return _parseVarDecl(
                  classId: _curClass?.id,
                  typeInferrence: true,
                  isOverrided: isOverrided,
                  isExternal: isExternal,
                  isStatic: isStatic,
                  lateInitialize: true);
            case HTLexicon.FUNCTION:
              return _parseFuncDecl(
                  category: FunctionCategory.method,
                  classId: _curClass?.id,
                  isOverrided: isOverrided,
                  isExternal: isExternal,
                  isStatic: isStatic);
            case HTLexicon.GET:
              return _parseFuncDecl(
                  category: FunctionCategory.getter,
                  classId: _curClass?.id,
                  isOverrided: isOverrided,
                  isExternal: isExternal,
                  isStatic: isStatic);
            case HTLexicon.SET:
              return _parseFuncDecl(
                  category: FunctionCategory.setter,
                  classId: _curClass?.id,
                  isOverrided: isOverrided,
                  isExternal: isExternal,
                  isStatic: isStatic);
            case HTLexicon.CONSTRUCT:
              if (isStatic) {
                final err = HTError.unexpected(
                    SemanticNames.declStmt, HTLexicon.CONSTRUCT,
                    moduleFullName: _curModuleFullName,
                    line: curTok.line,
                    column: curTok.column);
                errorHandler.handleError(err);
                final errToken = advance(1);
                return EmptyExpr(errToken.line, errToken.column);
              }
              return _parseFuncDecl(
                category: FunctionCategory.constructor,
                classId: _curClass?.id,
                isExternal: isExternal,
              );
            case HTLexicon.FACTORY:
              if (isStatic) {
                final err = HTError.unexpected(
                    SemanticNames.declStmt, HTLexicon.CONSTRUCT,
                    moduleFullName: _curModuleFullName,
                    line: curTok.line,
                    column: curTok.column);
                errorHandler.handleError(err);
                final errToken = advance(1);
                return EmptyExpr(errToken.line, errToken.column);
              }
              return _parseFuncDecl(
                category: FunctionCategory.factoryConstructor,
                classId: _curClass?.id,
                isExternal: isExternal,
              );
            default:
              final err = HTError.unexpected(
                  SemanticNames.declStmt, curTok.lexeme,
                  moduleFullName: _curModuleFullName,
                  line: curTok.line,
                  column: curTok.column);
              errorHandler.handleError(err);
              final errToken = advance(1);
              return EmptyExpr(errToken.line, errToken.column);
          }
        }
      case SourceType.function:
        if (curTok.lexeme == HTLexicon.TYPE) {
          return _parseTypeAliasDecl();
        } else {
          switch (curTok.type) {
            case HTLexicon.ABSTRACT:
              advance(1);
              return _parseClassDecl(isAbstract: true);
            case HTLexicon.ENUM:
              return _parseEnumDecl();
            case HTLexicon.CLASS:
              return _parseClassDecl();
            case HTLexicon.VAR:
              return _parseVarDecl(isMutable: true);
            case HTLexicon.LET:
              return _parseVarDecl(typeInferrence: true, isMutable: true);
            case HTLexicon.FINAL:
              return _parseVarDecl(typeInferrence: true);
            case HTLexicon.FUNCTION:
              if (expect([HTLexicon.FUNCTION, SemanticNames.identifier]) ||
                  expect([
                    HTLexicon.FUNCTION,
                    HTLexicon.squareLeft,
                    SemanticNames.identifier,
                    HTLexicon.squareRight,
                    SemanticNames.identifier
                  ])) {
                return _parseFuncDecl();
              } else {
                return _parseFuncDecl(category: FunctionCategory.literal);
              }
            case HTLexicon.IF:
              return _parseIfStmt();
            case HTLexicon.WHILE:
              return _parseWhileStmt();
            case HTLexicon.DO:
              return _parseDoStmt();
            case HTLexicon.FOR:
              return _parseForStmt();
            case HTLexicon.WHEN:
              return _parseWhenStmt();
            case HTLexicon.BREAK:
              final keyword = advance(1);
              return BreakStmt(keyword, keyword.line, keyword.column,
                  source: _curSource);
            case HTLexicon.CONTINUE:
              final keyword = advance(1);
              return ContinueStmt(keyword, keyword.line, keyword.column,
                  source: _curSource);
            case HTLexicon.RETURN:
              if (_curFuncCategory != null &&
                  _curFuncCategory != FunctionCategory.constructor) {
                return _parseReturnStmt();
              } else {
                final err = HTError.outsideReturn(
                    moduleFullName: _curModuleFullName,
                    line: curTok.line,
                    column: curTok.column);
                errorHandler.handleError(err);
                final errToken = advance(1);
                return EmptyExpr(errToken.line, errToken.column);
              }
            default:
              return _parseExprStmt();
          }
        }
      case SourceType.struct:
      case SourceType.expression:
        return _parseExpr();
    }
  }

  LibraryStmt _parseLibraryStmt() {
    final keyword = advance(1);

    _isLibrary = true;

    expect([HTLexicon.semicolon], consume: true);

    final stmt = LibraryStmt(keyword.line, keyword.column, source: _curSource);

    return stmt;
  }

  ImportStmt _parseImportStmt() {
    final keyword = advance(1);
    String key = match(SemanticNames.literalString).literal;
    String? alias;
    if (expect([HTLexicon.AS], consume: true)) {
      alias = match(SemanticNames.identifier).lexeme;
    }

    final showList = <String>[];
    if (curTok.lexeme == HTLexicon.SHOW) {
      advance(1);
      while (curTok.type == SemanticNames.identifier) {
        showList.add(advance(1).lexeme);
        if (curTok.type != HTLexicon.comma) {
          break;
        } else {
          advance(1);
        }
      }
    }

    expect([HTLexicon.semicolon], consume: true);

    final stmt = ImportStmt(key, keyword.line, keyword.column,
        source: _curSource, alias: alias, showList: showList);

    _curModuleImports.add(stmt);

    return stmt;
  }

  /// 使用递归向下的方法生成表达式, 不断调用更底层的, 优先级更高的子Parser
  ///
  /// 赋值 = , 优先级 1, 右合并
  ///
  /// 需要判断嵌套赋值、取属性、取下标的叠加
  AstNode _parseExpr() {
    if (curTok.type == SemanticNames.singleLineComment) {
      final comment = advance(1);
      return CommentExpr(comment.literal, false, comment.line, comment.column,
          source: _curSource);
    } else if (curTok.type == SemanticNames.multiLineComment) {
      final comment = advance(1);
      return CommentExpr(comment.literal, true, comment.line, comment.column,
          source: _curSource);
    } else {
      final left = _parserTernaryExpr();
      if (HTLexicon.assignments.contains(curTok.type)) {
        if (!_leftValueLegality) {
          final err = HTError.invalidLeftValue(
              moduleFullName: _curModuleFullName,
              line: curTok.line,
              column: curTok.column);
          errorHandler.handleError(err);
        }
        final op = advance(1);
        final right = _parseExpr();
        if (left is MemberExpr) {
          return MemberAssignExpr(
              left.object, left.key, right, left.line, left.column,
              source: _curSource);
        } else if (left is SubExpr) {
          return SubAssignExpr(
              left.array, left.key, right, left.line, left.column,
              source: _curSource);
        } else {
          return BinaryExpr(left, op.lexeme, right, op.line, op.column,
              source: _curSource);
        }
      } else {
        return left;
      }
    }
  }

  AstNode _parserTernaryExpr() {
    var condition = _parseLogicalOrExpr();
    if (expect([HTLexicon.condition], consume: true)) {
      _leftValueLegality = false;
      final thenBranch = _parserTernaryExpr();
      match(HTLexicon.colon);
      final elseBranch = _parserTernaryExpr();
      condition = TernaryExpr(
          condition, thenBranch, elseBranch, condition.line, condition.column,
          source: _curSource);
    }
    return condition;
  }

  /// 逻辑或 or , 优先级 5, 左合并
  AstNode _parseLogicalOrExpr() {
    var left = _parseLogicalAndExpr();
    if (curTok.type == HTLexicon.logicalOr) {
      _leftValueLegality = false;
      while (curTok.type == HTLexicon.logicalOr) {
        final op = advance(1); // and operator
        final right = _parseLogicalAndExpr();
        left = BinaryExpr(left, op.lexeme, right, op.line, op.column,
            source: _curSource);
      }
    }
    return left;
  }

  /// 逻辑和 and , 优先级 6, 左合并
  AstNode _parseLogicalAndExpr() {
    var left = _parseEqualityExpr();
    if (curTok.type == HTLexicon.logicalAnd) {
      _leftValueLegality = false;
      while (curTok.type == HTLexicon.logicalAnd) {
        final op = advance(1); // and operator
        final right = _parseEqualityExpr();
        left = BinaryExpr(left, op.lexeme, right, op.line, op.column,
            source: _curSource);
      }
    }
    return left;
  }

  /// 逻辑相等 ==, !=, 优先级 7, 不合并
  AstNode _parseEqualityExpr() {
    var left = _parseRelationalExpr();
    if (HTLexicon.equalitys.contains(curTok.type)) {
      _leftValueLegality = false;
      final op = advance(1);
      final right = _parseRelationalExpr();
      left = BinaryExpr(left, op.lexeme, right, op.line, op.column,
          source: _curSource);
    }
    return left;
  }

  /// 逻辑比较 <, >, <=, >=, as, is, is! 优先级 8, 不合并
  AstNode _parseRelationalExpr() {
    var left = _parseAdditiveExpr();
    if (HTLexicon.logicalRelationals.contains(curTok.type)) {
      _leftValueLegality = false;
      final op = advance(1);
      final right = _parseAdditiveExpr();
      left = BinaryExpr(left, op.lexeme, right, op.line, op.column,
          source: _curSource);
    } else if (HTLexicon.typeRelationals.contains(curTok.type)) {
      _leftValueLegality = false;
      final opTok = advance(1);
      late final String op;
      if (opTok.lexeme == HTLexicon.IS) {
        op = expect([HTLexicon.logicalNot], consume: true)
            ? HTLexicon.ISNOT
            : HTLexicon.IS;
      } else {
        op = opTok.lexeme;
      }
      final right = _parseTypeExpr(isLocal: true);
      left = BinaryExpr(left, op, right, opTok.line, opTok.column,
          source: _curSource);
    }
    return left;
  }

  /// 加法 +, -, 优先级 13, 左合并
  AstNode _parseAdditiveExpr() {
    var left = _parseMultiplicativeExpr();
    if (HTLexicon.additives.contains(curTok.type)) {
      _leftValueLegality = false;
      while (HTLexicon.additives.contains(curTok.type)) {
        final op = advance(1);
        final right = _parseMultiplicativeExpr();
        left = BinaryExpr(left, op.lexeme, right, op.line, op.column,
            source: _curSource);
      }
    }
    return left;
  }

  /// 乘法 *, /, %, 优先级 14, 左合并
  AstNode _parseMultiplicativeExpr() {
    var left = _parseUnaryPrefixExpr();
    if (HTLexicon.multiplicatives.contains(curTok.type)) {
      _leftValueLegality = false;
      while (HTLexicon.multiplicatives.contains(curTok.type)) {
        final op = advance(1);
        final right = _parseUnaryPrefixExpr();
        left = BinaryExpr(left, op.lexeme, right, op.line, op.column,
            source: _curSource);
      }
    }
    return left;
  }

  /// 前缀 -e, !e，++e, --e, 优先级 15, 不合并
  AstNode _parseUnaryPrefixExpr() {
    if (!(HTLexicon.unaryPrefixs.contains(curTok.type))) {
      return _parseUnaryPostfixExpr();
    } else {
      final op = advance(1);
      final value = _parseUnaryPostfixExpr();
      return UnaryPrefixExpr(op.lexeme, value, op.line, op.column,
          source: _curSource);
    }
  }

  /// 后缀 e., e[], e(), e++, e-- 优先级 16, 右合并
  AstNode _parseUnaryPostfixExpr() {
    var expr = _parsePrimaryExpr();
    while (HTLexicon.unaryPostfixs.contains(curTok.type)) {
      final op = advance(1);
      switch (op.type) {
        case HTLexicon.memberGet:
          _leftValueLegality = true;
          final name = match(SemanticNames.identifier);
          final key = SymbolExpr(name.lexeme, name.line, name.column,
              source: _curSource, isLocal: false);
          expr = MemberExpr(expr, key, op.line, op.column, source: _curSource);
          break;
        case HTLexicon.subGet:
          var indexExpr = _parseExpr();
          _leftValueLegality = true;
          match(HTLexicon.squareRight);
          expr =
              SubExpr(expr, indexExpr, op.line, op.column, source: _curSource);
          break;
        case HTLexicon.call:
          // TODO: typeArgs: typeArgs
          _leftValueLegality = false;
          var positionalArgs = <AstNode>[];
          var namedArgs = <String, AstNode>{};
          _handleCallArguments(positionalArgs, namedArgs);
          expr = CallExpr(expr, positionalArgs, namedArgs, op.line, op.column,
              source: _curSource);
          break;
        case HTLexicon.postIncrement:
        case HTLexicon.postDecrement:
          _leftValueLegality = false;
          expr = UnaryPostfixExpr(expr, op.lexeme, op.line, op.column,
              source: _curSource);
          break;
        default:
          break;
      }
    }
    return expr;
  }

  /// Expression without operators
  AstNode _parsePrimaryExpr() {
    switch (curTok.type) {
      case HTLexicon.NULL:
        _leftValueLegality = false;
        final token = advance(1);
        return NullExpr(token.line, token.column, source: _curSource);
      case SemanticNames.literalBoolean:
        _leftValueLegality = false;
        final token = advance(1) as TokenBooleanLiteral;
        return BooleanExpr(token.literal, token.line, token.column,
            source: _curSource);
      case SemanticNames.literalInteger:
        _leftValueLegality = false;
        final token = advance(1) as TokenIntLiteral;
        return ConstIntExpr(token.literal, token.line, token.column,
            source: _curSource);
      case SemanticNames.literalFloat:
        _leftValueLegality = false;
        final token = advance(1) as TokenFloatLiteral;
        return ConstFloatExpr(token.literal, token.line, token.column,
            source: _curSource);
      case SemanticNames.literalString:
        _leftValueLegality = false;
        final token = advance(1) as TokenStringLiteral;
        return ConstStringExpr.fromToken(token, source: _curSource);
      case SemanticNames.stringInterpolation:
        _leftValueLegality = false;
        final token = advance(1) as TokenStringInterpolation;
        final interpolation = <AstNode>[];
        for (final tokens in token.interpolations) {
          final exprParser = HTAstParser(
              config: ParserConfigImpl(sourceType: SourceType.expression),
              errorHandler: errorHandler,
              sourceProvider: sourceProvider);
          final nodes = exprParser.parse(tokens, _curSource);
          if (nodes.length > 1) {
            final err = HTError.stringInterpolation(
                moduleFullName: _curModuleFullName,
                line: nodes.first.line,
                column: nodes.first.column);
            errorHandler.handleError(err);
            final errToken = EmptyExpr(token.line, token.column);
            interpolation.add(errToken);
          } else {
            interpolation.add(nodes.first);
          }
        }
        var i = 0;
        final value = token.literal.replaceAllMapped(
            RegExp(HTLexicon.stringInterpolationPattern),
            (Match m) => '${HTLexicon.curlyLeft}${i++}${HTLexicon.curlyRight}');
        return StringInterpolationExpr(value, token.quotationLeft,
            token.quotationRight, interpolation, token.line, token.column,
            source: _curSource);
      case HTLexicon.THIS:
        _leftValueLegality = false;
        final keyword = advance(1);
        return SymbolExpr(keyword.lexeme, keyword.line, keyword.column,
            source: _curSource);
      case HTLexicon.SUPER:
        _leftValueLegality = false;
        final keyword = advance(1);
        return SymbolExpr(keyword.lexeme, keyword.line, keyword.column,
            source: _curSource);
      case HTLexicon.roundLeft:
        _leftValueLegality = false;
        final punc = advance(1);
        final innerExpr = _parseExpr();
        match(HTLexicon.roundRight);
        return GroupExpr(innerExpr, punc.line, punc.column, source: _curSource);
      case HTLexicon.squareLeft:
        _leftValueLegality = false;
        final line = curTok.line;
        final column = advance(1).column;
        var listExpr = <AstNode>[];
        while (curTok.type != HTLexicon.squareRight) {
          listExpr.add(_parseExpr());
          if (curTok.type != HTLexicon.squareRight) {
            match(HTLexicon.comma);
          }
        }
        match(HTLexicon.squareRight);
        return ListExpr(listExpr, line, column, source: _curSource);
      case HTLexicon.curlyLeft:
        _leftValueLegality = false;
        final line = curTok.line;
        final column = advance(1).column;
        var mapExpr = <AstNode, AstNode>{};
        while (curTok.type != HTLexicon.curlyRight) {
          var keyExpr = _parseExpr();
          match(HTLexicon.colon);
          var valueExpr = _parseExpr();
          mapExpr[keyExpr] = valueExpr;
          if (curTok.type != HTLexicon.curlyRight) {
            match(HTLexicon.comma);
          }
        }
        match(HTLexicon.curlyRight);
        return MapExpr(line, column, source: _curSource, map: mapExpr);
      case HTLexicon.FUNCTION:
        return _parseFuncDecl(category: FunctionCategory.literal);
      case SemanticNames.identifier:
        // literal function type
        if (curTok.lexeme == HTLexicon.function) {
          _leftValueLegality = false;
          return _parseTypeExpr();
        }
        // TODO: literal interface type
        else {
          _leftValueLegality = true;
          final symbol = advance(1);
          // TODO: type arguments
          return SymbolExpr(symbol.lexeme, symbol.line, symbol.column,
              source: _curSource);
        }
      default:
        final err = HTError.unexpected(SemanticNames.expression, curTok.lexeme,
            moduleFullName: _curModuleFullName,
            line: curTok.line,
            column: curTok.column);
        errorHandler.handleError(err);
        final errToken = advance(1);
        return EmptyExpr(errToken.line, errToken.column);
    }
  }

  TypeExpr _parseTypeExpr({bool isLocal = false}) {
    // function type
    if (curTok.lexeme != HTLexicon.FUNCTION) {
      final id = match(SemanticNames.identifier);
      final typeArgs = <TypeExpr>[];
      if (expect([HTLexicon.angleLeft], consume: true)) {
        if (curTok.type == HTLexicon.angleRight) {
          final err = HTError.emptyTypeArgs(
              moduleFullName: _curModuleFullName,
              line: curTok.line,
              column: curTok.column);
          errorHandler.handleError(err);
        }
        while ((curTok.type != HTLexicon.angleRight) &&
            (curTok.type != SemanticNames.endOfFile)) {
          typeArgs.add(_parseTypeExpr());
          expect([HTLexicon.comma], consume: true);
        }
        match(HTLexicon.angleRight);
      }
      final isNullable = expect([HTLexicon.nullable], consume: true);
      return TypeExpr(id.lexeme, id.line, id.column,
          source: _curSource,
          arguments: typeArgs,
          isNullable: isNullable,
          isLocal: isLocal);
    }
    // TODO: interface type
    else {
      final keyword = advance(1);
      // TODO: genericTypeParameters 泛型参数
      final parameters = <ParamTypeExpr>[];
      var isOptional = false;
      var isNamed = false;
      var isVariadic = false;
      match(HTLexicon.roundLeft);
      while (curTok.type != HTLexicon.roundRight &&
          curTok.type != SemanticNames.endOfFile) {
        final line = curTok.line;
        final column = curTok.column;
        if (!isOptional) {
          isOptional = expect([HTLexicon.squareLeft], consume: true);
          if (!isOptional && !isNamed) {
            isNamed = expect([HTLexicon.curlyLeft], consume: true);
          }
        }
        late final paramType;
        String? paramId;
        if (!isNamed) {
          isVariadic = expect([HTLexicon.variadicArgs], consume: true);
        } else {
          paramId = match(SemanticNames.identifier).lexeme;
          match(HTLexicon.colon);
        }
        paramType = _parseTypeExpr();
        final param = ParamTypeExpr(paramType, line, column,
            source: _curSource,
            isOptional: isOptional,
            isVariadic: isVariadic,
            id: paramId);
        parameters.add(param);
        if (isOptional && expect([HTLexicon.squareRight], consume: true)) {
          break;
        } else if (isNamed && expect([HTLexicon.curlyRight], consume: true)) {
          break;
        } else if (curTok.type != HTLexicon.roundRight) {
          match(HTLexicon.comma);
        }
        if (isVariadic) {
          break;
        }
      }
      match(HTLexicon.roundRight);
      match(HTLexicon.singleArrow);
      final returnType = _parseTypeExpr();
      return FuncTypeExpr(returnType, keyword.line, keyword.column,
          source: _curSource,
          paramTypes: parameters,
          hasOptionalParam: isOptional,
          hasNamedParam: isNamed);
    }
  }

  BlockStmt _parseBlockStmt(
      {String? id,
      SourceType sourceType = SourceType.function,
      bool hasOwnNamespace = true}) {
    final token = match(HTLexicon.curlyLeft);
    final statements = <AstNode>[];
    while (curTok.type != HTLexicon.curlyRight &&
        curTok.type != SemanticNames.endOfFile) {
      final stmt = _parseStmt(sourceType: sourceType);
      statements.add(stmt);
    }
    match(HTLexicon.curlyRight);
    return BlockStmt(statements, token.line, token.column,
        source: _curSource, id: id, hasOwnNamespace: hasOwnNamespace);
  }

  void _handleCallArguments(
      List<AstNode> positionalArgs, Map<String, AstNode> namedArgs) {
    var isNamed = false;
    while ((curTok.type != HTLexicon.roundRight) &&
        (curTok.type != SemanticNames.endOfFile)) {
      if ((!isNamed &&
              expect([SemanticNames.identifier, HTLexicon.colon],
                  consume: false)) ||
          isNamed) {
        isNamed = true;
        final name = match(SemanticNames.identifier).lexeme;
        match(HTLexicon.colon);
        final value = _parseExpr();
        namedArgs[name] = value;
      } else {
        positionalArgs.add(_parseExpr());
      }
      if (curTok.type != HTLexicon.roundRight) {
        match(HTLexicon.comma);
      }
    }
    match(HTLexicon.roundRight);
  }

  ExprStmt _parseExprStmt() {
    AstNode? expr;
    if (curTok.type != HTLexicon.semicolon) {
      expr = _parseExpr();
    }
    // 语句结尾
    expect([HTLexicon.semicolon], consume: true);
    return ExprStmt(expr, curTok.line, curTok.column, source: _curSource);
  }

  ReturnStmt _parseReturnStmt() {
    var keyword = advance(1);
    AstNode? expr;
    if (curTok.type != HTLexicon.curlyRight &&
        curTok.type != HTLexicon.semicolon &&
        curTok.type != SemanticNames.endOfFile) {
      expr = _parseExpr();
    }
    expect([HTLexicon.semicolon], consume: true);
    return ReturnStmt(keyword, expr, keyword.line, keyword.column,
        source: _curSource);
  }

  IfStmt _parseIfStmt() {
    final keyword = advance(1);
    var condition = _parseExpr();
    late BlockStmt thenBranch;
    if (curTok.type == HTLexicon.curlyLeft) {
      thenBranch = _parseBlockStmt(id: SemanticNames.thenBranch);
    } else {
      final stmt = _parseStmt();
      thenBranch = BlockStmt([stmt], stmt.line, stmt.column,
          source: _curSource, id: SemanticNames.thenBranch);
    }
    BlockStmt? elseBranch;
    if (expect([HTLexicon.ELSE], consume: true)) {
      if (curTok.type == HTLexicon.curlyLeft) {
        elseBranch = _parseBlockStmt(id: SemanticNames.elseBranch);
      } else {
        final stmt = _parseStmt();
        elseBranch = BlockStmt([stmt], stmt.line, stmt.column,
            source: _curSource, id: SemanticNames.elseBranch);
      }
    }
    return IfStmt(
        condition, thenBranch, elseBranch, keyword.line, keyword.column,
        source: _curSource);
  }

  WhileStmt _parseWhileStmt() {
    final keyword = advance(1);
    final condition = _parseExpr();
    late BlockStmt loop;
    if (curTok.type == HTLexicon.curlyLeft) {
      loop = _parseBlockStmt(id: SemanticNames.whileLoop);
    } else {
      final stmt = _parseStmt();
      loop = BlockStmt([stmt], stmt.line, stmt.column,
          source: _curSource, id: SemanticNames.whileLoop);
    }
    return WhileStmt(condition, loop, keyword.line, keyword.column,
        source: _curSource);
  }

  DoStmt _parseDoStmt() {
    final keyword = advance(1);
    late BlockStmt loop;
    if (curTok.type == HTLexicon.curlyLeft) {
      loop = _parseBlockStmt(id: SemanticNames.doLoop);
    } else {
      final stmt = _parseStmt();
      loop = BlockStmt([stmt], stmt.line, stmt.column,
          source: _curSource, id: SemanticNames.doLoop);
    }
    AstNode? condition;
    if (expect([HTLexicon.WHILE], consume: true)) {
      condition = _parseExpr();
    }
    return DoStmt(loop, condition, keyword.line, keyword.column,
        source: _curSource);
  }

  AstNode _parseForStmt() {
    final keyword = advance(1);
    final hasBracket = expect([HTLexicon.roundLeft], consume: true);
    final forStmtType = peek(2).lexeme;
    VarDeclStmt? declaration;
    AstNode? condition;
    AstNode? increment;
    final newSymbolMap = <String, String>{};
    _markedSymbolsList.add(newSymbolMap);
    if (forStmtType == HTLexicon.IN) {
      if (!HTLexicon.varDeclKeywords.contains(curTok.type)) {
        final err = HTError.unexpected(
            SemanticNames.variableDeclaration, curTok.type,
            moduleFullName: _curModuleFullName,
            line: curTok.line,
            column: curTok.column);
        errorHandler.handleError(err);
      }
      declaration = _parseVarDecl(
          typeInferrence: curTok.type != HTLexicon.VAR,
          isMutable: curTok.type != HTLexicon.FINAL);

      advance(1);

      final collection = _parseExpr();

      if (hasBracket) {
        match(HTLexicon.roundRight);
      }

      final loop = _parseBlockStmt(id: SemanticNames.forLoop);

      return ForInStmt(
          declaration, collection, loop, keyword.line, keyword.column,
          hasBracket: hasBracket, source: _curSource);
    } else {
      if (!expect([HTLexicon.semicolon], consume: false)) {
        declaration = _parseVarDecl(
            typeInferrence: curTok.type != HTLexicon.VAR,
            isMutable: curTok.type != HTLexicon.FINAL,
            endOfStatement: true);
      } else {
        match(HTLexicon.semicolon);
      }

      if (!expect([HTLexicon.semicolon], consume: false)) {
        condition = _parseExpr();
      }
      match(HTLexicon.semicolon);

      if (!expect([HTLexicon.roundRight], consume: false)) {
        increment = _parseExpr();
      }

      if (hasBracket) {
        match(HTLexicon.roundRight);
      }

      final loop = _parseBlockStmt(id: SemanticNames.forLoop);

      return ForStmt(
          declaration, condition, increment, loop, keyword.line, keyword.column,
          hasBracket: hasBracket, source: _curSource);
    }
  }

  WhenStmt _parseWhenStmt() {
    final keyword = advance(1);
    AstNode? condition;
    if (curTok.type != HTLexicon.curlyLeft) {
      condition = _parseExpr();
    }
    final options = <AstNode, AstNode>{};
    BlockStmt? elseBranch;
    match(HTLexicon.curlyLeft);
    while (curTok.type != HTLexicon.curlyRight &&
        curTok.type != SemanticNames.endOfFile) {
      if (curTok.lexeme == HTLexicon.ELSE) {
        advance(1);
        match(HTLexicon.singleArrow);
        if (curTok.type == HTLexicon.curlyLeft) {
          elseBranch = _parseBlockStmt(id: SemanticNames.elseBranch);
        } else {
          final stmt = _parseStmt();
          elseBranch = BlockStmt([stmt], stmt.line, stmt.column,
              source: _curSource, id: SemanticNames.elseBranch);
        }
      } else {
        final caseExpr = _parseExpr();
        match(HTLexicon.singleArrow);
        late final caseBranch;
        if (curTok.type == HTLexicon.curlyLeft) {
          caseBranch = _parseBlockStmt(id: SemanticNames.whenBranch);
        } else {
          final stmt = _parseStmt();
          caseBranch = BlockStmt([stmt], stmt.line, stmt.column,
              source: _curSource, id: SemanticNames.whenBranch);
        }
        options[caseExpr] = caseBranch;
      }
    }
    match(HTLexicon.curlyRight);
    return WhenStmt(
        options, elseBranch, condition, keyword.line, keyword.column,
        source: _curSource);
  }

  TypeAliasDeclStmt _parseTypeAliasDecl(
      {String? classId, bool isExported = false, bool isTopLevel = false}) {
    final keyword = advance(1);
    final id = match(SemanticNames.identifier).lexeme;
    final genericParameters = <TypeExpr>[];
    match(HTLexicon.assign);
    final value = _parseTypeExpr();
    return TypeAliasDeclStmt(id, value, keyword.line, keyword.column,
        source: _curSource,
        classId: classId,
        genericParameters: genericParameters,
        isExported: isExported,
        isTopLevel: isTopLevel);
  }

  VarDeclStmt _parseVarDecl(
      {String? classId,
      bool typeInferrence = false,
      bool isOverrided = false,
      bool isExternal = false,
      bool isStatic = false,
      bool isConst = false,
      bool isMutable = false,
      bool isExported = false,
      bool isTopLevel = false,
      bool lateInitialize = false,
      AstNode? additionalInitializer,
      bool endOfStatement = false}) {
    advance(1);
    var idTok = match(SemanticNames.identifier);
    var id = idTok.lexeme;

    if (classId != null && isExternal) {
      if (!(_curClass!.isExternal) && !isStatic) {
        final err = HTError.externalMember(
            moduleFullName: _curModuleFullName,
            line: idTok.line,
            column: idTok.column);
        errorHandler.handleError(err);
      }
      id = '$classId.$id';
    }

    var declType;
    if (expect([HTLexicon.colon], consume: true)) {
      declType = _parseTypeExpr();
    }

    var initializer = additionalInitializer;
    if (expect([HTLexicon.assign], consume: true)) {
      initializer = _parseExpr();
    }

    if (endOfStatement) {
      match(HTLexicon.semicolon);
    } else {
      expect([HTLexicon.semicolon], consume: true);
    }

    return VarDeclStmt(id, idTok.line, idTok.column,
        source: _curSource,
        classId: classId,
        declType: declType,
        initializer: initializer,
        typeInferrence: typeInferrence,
        isExternal: isExternal,
        isStatic: isStatic,
        isConst: isConst,
        isMutable: isMutable,
        isExported: isExported,
        isTopLevel: isTopLevel,
        lateInitialize: lateInitialize);
  }

  FuncDeclExpr _parseFuncDecl(
      {FunctionCategory category = FunctionCategory.normal,
      String? classId,
      bool isOverrided = false,
      bool isExternal = false,
      bool isStatic = false,
      bool isConst = false,
      bool isExported = false,
      bool isTopLevel = false}) {
    final savedCurFuncType = _curFuncCategory;
    _curFuncCategory = category;
    final keyword = advance(1);
    String? externalTypedef;
    if (!isExternal &&
        (isStatic ||
            category == FunctionCategory.normal ||
            category == FunctionCategory.literal)) {
      if (expect([HTLexicon.squareLeft], consume: true)) {
        if (isExternal) {
          final err = HTError.internalFuncWithExternalTypeDef(
              moduleFullName: _curModuleFullName,
              line: curTok.line,
              column: curTok.column);
          errorHandler.handleError(err);
        }
        externalTypedef = match(SemanticNames.identifier).lexeme;
        match(HTLexicon.squareRight);
      }
    }
    String? id;
    late String internalName;
    if (curTok.type == SemanticNames.identifier) {
      id = advance(1).lexeme;
    }
    switch (category) {
      case FunctionCategory.constructor:
        internalName = (id == null)
            ? SemanticNames.constructor
            : '${SemanticNames.constructor}$id';
        break;
      case FunctionCategory.getter:
        internalName = '${SemanticNames.getter}$id';
        break;
      case FunctionCategory.setter:
        internalName = '${SemanticNames.setter}$id';
        break;
      case FunctionCategory.literal:
        internalName = SemanticNames.anonymousFunction +
            (AbstractParser.anonymousFuncIndex++).toString();
        break;
      default:
        internalName = id!;
    }
    final genericParameters = <TypeExpr>[];
    var isFuncVariadic = false;
    var minArity = 0;
    var maxArity = 0;
    var paramDecls = <ParamDeclExpr>[];
    var hasParamDecls = false;
    if (category != FunctionCategory.getter &&
        expect([HTLexicon.roundLeft], consume: true)) {
      hasParamDecls = true;
      var isOptional = false;
      var isNamed = false;
      var isVariadic = false;
      while ((curTok.type != HTLexicon.roundRight) &&
          (curTok.type != HTLexicon.squareRight) &&
          (curTok.type != HTLexicon.curlyRight) &&
          (curTok.type != SemanticNames.endOfFile)) {
        // 可选参数, 根据是否有方括号判断, 一旦开始了可选参数, 则不再增加参数数量arity要求
        if (!isOptional) {
          isOptional = expect([HTLexicon.squareLeft], consume: true);
          if (!isOptional && !isNamed) {
            //检查命名参数, 根据是否有花括号判断
            isNamed = expect([HTLexicon.curlyLeft], consume: true);
          }
        }
        if (!isNamed) {
          isVariadic = expect([HTLexicon.variadicArgs], consume: true);
        }
        if (!isNamed && !isVariadic) {
          if (!isOptional) {
            ++minArity;
            ++maxArity;
          } else {
            ++maxArity;
          }
        }
        var paramId = match(SemanticNames.identifier);
        TypeExpr? paramDeclType;
        if (expect([HTLexicon.colon], consume: true)) {
          paramDeclType = _parseTypeExpr();
        }
        AstNode? initializer;
        if (expect([HTLexicon.assign], consume: true)) {
          if (isOptional || isNamed) {
            initializer = _parseExpr();
          } else {
            final err = HTError.argInit(
                moduleFullName: _curModuleFullName,
                line: curTok.line,
                column: curTok.column);
            errorHandler.handleError(err);
          }
        }
        final param = ParamDeclExpr(
            paramId.lexeme, paramId.line, paramId.column,
            source: _curSource,
            declType: paramDeclType,
            initializer: initializer,
            isVariadic: isVariadic,
            isOptional: isOptional,
            isNamed: isNamed);
        paramDecls.add(param);
        if (curTok.type != HTLexicon.squareRight &&
            curTok.type != HTLexicon.curlyRight &&
            curTok.type != HTLexicon.roundRight) {
          match(HTLexicon.comma);
        }
        if (isVariadic) {
          isFuncVariadic = true;
          break;
        }
      }
      if (isOptional) {
        match(HTLexicon.squareRight);
      } else if (isNamed) {
        match(HTLexicon.curlyRight);
      }

      match(HTLexicon.roundRight);

      // setter can only have one parameter
      if ((category == FunctionCategory.setter) && (minArity != 1)) {
        final err = HTError.setterArity(
            moduleFullName: _curModuleFullName,
            line: curTok.line,
            column: curTok.column);
        errorHandler.handleError(err);
      }
    }
    TypeExpr? returnType;
    ReferConstructorExpr? referCtor;
    // the return value type declaration
    if (expect([HTLexicon.singleArrow], consume: true)) {
      if (category == FunctionCategory.constructor) {
        final err = HTError.ctorReturn(
            moduleFullName: _curModuleFullName,
            line: curTok.line,
            column: curTok.column);
        errorHandler.handleError(err);
      }
      returnType = _parseTypeExpr();
    }
    // referring to another constructor
    else if (expect([HTLexicon.colon], consume: true)) {
      if (category != FunctionCategory.constructor) {
        final err = HTError.nonCotrWithReferCtor(
            moduleFullName: _curModuleFullName,
            line: curTok.line,
            column: curTok.column);
        errorHandler.handleError(err);
      }
      if (isExternal) {
        final err = HTError.externalCtorWithReferCtor(
            moduleFullName: _curModuleFullName,
            line: curTok.line,
            column: curTok.column);
        errorHandler.handleError(err);
      }
      final ctorCallee = advance(1);
      if (!HTLexicon.constructorCall.contains(ctorCallee.lexeme)) {
        final err = HTError.unexpected(
            SemanticNames.ctorCallExpr, curTok.lexeme,
            moduleFullName: _curModuleFullName,
            line: curTok.line,
            column: curTok.column);
        errorHandler.handleError(err);
      }
      String? ctorKey;
      if (expect([HTLexicon.memberGet], consume: true)) {
        ctorKey = match(SemanticNames.identifier).lexeme;
        match(HTLexicon.roundLeft);
      } else {
        match(HTLexicon.roundLeft);
      }
      var positionalArgs = <AstNode>[];
      var namedArgs = <String, AstNode>{};
      _handleCallArguments(positionalArgs, namedArgs);
      referCtor = ReferConstructorExpr(
        ctorCallee.lexeme == HTLexicon.SUPER,
        ctorKey,
        positionalArgs,
        namedArgs,
        ctorCallee.line,
        ctorCallee.column,
        source: _curSource,
      );
    }
    AstNode? definition;
    if (curTok.type == HTLexicon.curlyLeft) {
      definition = _parseBlockStmt(id: SemanticNames.functionCall);
    } else if (expect([HTLexicon.assign], consume: true)) {
      definition = _parseExprStmt();
    } else {
      if (category != FunctionCategory.constructor &&
          category != FunctionCategory.literal &&
          !isExternal &&
          !(_curClass?.isAbstract ?? false)) {
        final err = HTError.missingFuncBody(internalName,
            moduleFullName: _curModuleFullName,
            line: curTok.line,
            column: curTok.column);
        errorHandler.handleError(err);
      }
      expect([HTLexicon.semicolon], consume: true);
    }
    _curFuncCategory = savedCurFuncType;
    return FuncDeclExpr(internalName, paramDecls, keyword.line, keyword.column,
        id: id,
        source: _curSource,
        classId: classId,
        genericParameters: genericParameters,
        externalTypeId: externalTypedef,
        returnType: returnType,
        referConstructor: referCtor,
        hasParamDecls: hasParamDecls,
        minArity: minArity,
        maxArity: maxArity,
        definition: definition,
        isExternal: isExternal,
        isStatic: isStatic,
        isConst: isConst,
        isVariadic: isFuncVariadic,
        isExported: isExported,
        isTopLevel: isTopLevel,
        category: category);
  }

  ClassDeclStmt _parseClassDecl(
      {String? classId,
      bool isNested = false,
      bool isExternal = false,
      bool isAbstract = false,
      bool isExported = false,
      bool isTopLevel = false}) {
    if (_curClass != null && _curClass!.isNested) {
      final err = HTError.nestedClass(
          moduleFullName: _curModuleFullName,
          line: curTok.line,
          column: curTok.column);
      errorHandler.handleError(err);
    }
    final keyword = match(HTLexicon.CLASS);
    final id = match(SemanticNames.identifier);
    final genericParameters = <TypeExpr>[];
    if (expect([HTLexicon.angleLeft], consume: true)) {
      while ((curTok.type != HTLexicon.angleRight) &&
          (curTok.type != SemanticNames.endOfFile)) {
        if (genericParameters.isNotEmpty) {
          match(HTLexicon.comma);
        }
        final typeExpr = _parseTypeExpr();
        genericParameters.add(typeExpr);
      }
      match(HTLexicon.angleRight);
    }
    TypeExpr? superClassType;
    if (expect([HTLexicon.EXTENDS], consume: true)) {
      if (curTok.lexeme == id.lexeme) {
        final err = HTError.extendsSelf(
            moduleFullName: _curModuleFullName,
            line: curTok.line,
            column: curTok.column);
        errorHandler.handleError(err);
      }

      superClassType = _parseTypeExpr();
    }
    final savedClass = _curClass;
    _curClass = HTClassDeclaration(
        id: id.lexeme,
        classId: classId,
        isNested: isNested,
        isExternal: isExternal,
        isAbstract: isAbstract);

    final definition = _parseBlockStmt(
        sourceType: SourceType.klass,
        hasOwnNamespace: false,
        id: SemanticNames.classDefinition);
    _curClass = savedClass;
    return ClassDeclStmt(id.lexeme, keyword.line, keyword.column,
        source: _curSource,
        genericParameters: genericParameters,
        superType: superClassType,
        isNested: isNested,
        isExternal: isExternal,
        isAbstract: isAbstract,
        isExported: isExported,
        isTopLevel: isTopLevel,
        definition: definition);
  }

  EnumDeclStmt _parseEnumDecl(
      {bool isExternal = false,
      bool isExported = true,
      bool isTopLevel = false}) {
    final keyword = match(HTLexicon.ENUM);
    final id = match(SemanticNames.identifier);
    var enumerations = <String>[];
    if (expect([HTLexicon.curlyLeft], consume: true)) {
      while (curTok.type != HTLexicon.curlyRight &&
          curTok.type != SemanticNames.endOfFile) {
        enumerations.add(match(SemanticNames.identifier).lexeme);
        if (curTok.type != HTLexicon.curlyRight) {
          match(HTLexicon.comma);
        }
      }
      match(HTLexicon.curlyRight);
    } else {
      expect([HTLexicon.semicolon], consume: true);
    }
    return EnumDeclStmt(id.lexeme, enumerations, keyword.line, keyword.column,
        source: _curSource,
        isExternal: isExternal,
        isExported: isExported,
        isTopLevel: isTopLevel);
  }
}
