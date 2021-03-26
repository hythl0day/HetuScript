import 'dart:collection';

import '../interpreter.dart';
import '../type.dart';
import '../common.dart';
import '../lexicon.dart';
import 'compiler.dart';
import 'opcode.dart';
import '../lexer.dart';
import '../errors.dart';
import '../plugin/moduleHandler.dart';
import '../namespace.dart';
import '../plugin/errorHandler.dart';
import 'bytes_reader.dart';
import 'bytes_declaration.dart';
import 'bytes_funciton.dart';
import '../declaration.dart';
import '../class.dart';
import '../extern_object.dart';
import '../object.dart';

mixin VMRef {
  late final HTVM interpreter;
}

class HTVM extends Interpreter {
  late BytesReader _bytesReader;

  dynamic _curValue; // local value
  String? _curSymbol;
  String? _curClassName;

  final _register = List<dynamic>.filled(24, null, growable: false);

  var _curRefType = ReferrenceType.normal;

  /// 每有一个赋值符号，就会添加一个左值类型
  final _leftValueStack = <ReferrenceType>[];

  /// break 指令将会跳回最近的一个break point
  /// [key]: 原本的指令指针位置
  /// [value]: 原本的命名空间
  final LinkedHashMap<int, HTNamespace> _breakPoint = LinkedHashMap<int, HTNamespace>();

  HTVM({HTErrorHandler? errorHandler, HTModuleHandler? importHandler})
      : super(errorHandler: errorHandler, importHandler: importHandler);

  @override
  Future<dynamic> eval(
    String content, {
    String? fileName,
    String libName = HTLexicon.global,
    HTNamespace? namespace,
    ParseStyle style = ParseStyle.module,
    bool debugMode = false,
    String? invokeFunc,
    List<dynamic> positionalArgs = const [],
    Map<String, dynamic> namedArgs = const {},
  }) async {
    curFileName = fileName ?? HTLexicon.anonymousScript;
    curNamespace = namespace ?? global;

    final tokens = Lexer().lex(content, curFileName);
    final bytes = await Compiler().compile(tokens, this, curFileName, style, debugMode);
    _bytesReader = BytesReader(bytes);
    print(bytes);

    var result = execute(closure: curNamespace);
    if (style == ParseStyle.module && invokeFunc != null) {
      result = invoke(invokeFunc, positionalArgs: positionalArgs, namedArgs: namedArgs);
    }

    return result;
  }

  @override
  Future<dynamic> import(
    String fileName, {
    String? directory,
    String? libName,
    ParseStyle style = ParseStyle.module,
    String? invokeFunc,
    List<dynamic> positionalArgs = const [],
    Map<String, dynamic> namedArgs = const {},
  }) async {}

  @override
  HTTypeId typeof(dynamic object) {
    return HTTypeId.ANY;
  }

  /// 从 [ip] 位置开始解释，遇到 OP.return 后返回当前值。
  /// 返回时，指针会回到执行前的 ip 位置。并且会回到之前的命名空间。
  dynamic execute({int? ip, HTNamespace? closure}) {
    final savedIp = _bytesReader.ip;
    final savedNamespace = curNamespace;

    if (ip != null) {
      _bytesReader.ip = ip;
    }
    if (closure != null) {
      curNamespace = closure;
    }

    final result = _execute();

    if (ip != null) {
      _bytesReader.ip = savedIp;
    }
    if (closure != null) {
      curNamespace = savedNamespace;
    }

    return result;
  }

  dynamic _execute() {
    var instruction = _bytesReader.read();
    while (instruction != HTOpCode.endOfFile) {
      switch (instruction) {
        case HTOpCode.signature:
          _bytesReader.readUint32();
          break;
        case HTOpCode.version:
          final major = _bytesReader.read();
          final minor = _bytesReader.read();
          final patch = _bytesReader.readUint16();
          scriptVersion = HTVersion(major, minor, patch);
          break;
        case HTOpCode.debug:
          debugMode = _bytesReader.read() == 0 ? false : true;
          break;
        // 将字面量存储在本地变量中
        case HTOpCode.local:
          _storeLocal();
          break;
        // 将本地变量存入下一个字节代表的寄存器位置中
        case HTOpCode.register:
          _storeRegister(_bytesReader.read(), _curValue);
          break;
        // case HTOpCode.leftValue:
        //   final refType = ReferrenceType.values.elementAt(_bytesReader.read());
        //   _leftValueStack.add(refType);
        //   break;
        case HTOpCode.goto:
          final distance = _bytesReader.readInt16();
          _bytesReader.ip += distance;
          break;
        // 循环开始，记录断点
        case HTOpCode.loop:
          _breakPoint[_bytesReader.ip] = curNamespace;
          break;
        // 匿名语句块，blockStart 一定要和 blockEnd 成对出现
        case HTOpCode.block:
          final id = _bytesReader.readShortUtf8String();
          curNamespace = HTNamespace(this, id: id, closure: curNamespace);
          break;
        case HTOpCode.endOfBlock:
          curNamespace = curNamespace.closure!;
          break;
        // 语句结束
        case HTOpCode.endOfStmt:
          _curSymbol = null;
          break;
        case HTOpCode.endOfExec:
          return _curValue;
        case HTOpCode.breakLoop:
          _bytesReader.ip = _breakPoint.keys.last;
          curNamespace = _breakPoint.values.last;
          _breakPoint.remove(_bytesReader.ip);
          break;
        case HTOpCode.continueLoop:
          _bytesReader.ip = _breakPoint.keys.last;
          curNamespace = _breakPoint.values.last;
          break;
        //常量表
        case HTOpCode.constTable:
          final int64Length = _bytesReader.readUint16();
          for (var i = 0; i < int64Length; ++i) {
            curNamespace.addConstInt(_bytesReader.readInt64());
          }
          final float64Length = _bytesReader.readUint16();
          for (var i = 0; i < float64Length; ++i) {
            curNamespace.addConstFloat(_bytesReader.readFloat64());
          }
          final utf8StringLength = _bytesReader.readUint16();
          for (var i = 0; i < utf8StringLength; ++i) {
            curNamespace.addConstString(_bytesReader.readUtf8String());
          }
          break;
        // 变量表
        case HTOpCode.declTable:
          var funcDeclLength = _bytesReader.readUint16();
          for (var i = 0; i < funcDeclLength; ++i) {
            _handleFuncDecl();
          }
          var classDeclLength = _bytesReader.readUint16();
          for (var i = 0; i < classDeclLength; ++i) {
            _handleClassDecl();
          }
          var varDeclLength = _bytesReader.readUint16();
          for (var i = 0; i < varDeclLength; ++i) {
            _handleVarDecl();
          }
          break;
        case HTOpCode.ifStmt:
          bool condition = _curValue;
          final thenBranchLength = _bytesReader.readUint16();
          final elseBranchLength = _bytesReader.readUint16();
          if (condition) {
            execute();
            _bytesReader.skip(thenBranchLength + elseBranchLength);
          } else {
            _bytesReader.skip(thenBranchLength);
            execute();
            _bytesReader.skip(elseBranchLength);
          }
          break;
        case HTOpCode.whileStmt:
          final hasCondition = _bytesReader.readBool();
          final distance = _bytesReader.readUint16();
          if (hasCondition && !_curValue) {
            _bytesReader.skip(distance);
          }
          break;
        case HTOpCode.forStmt:
          // _handleForStmt();
          break;
        case HTOpCode.whenStmt:
          // _handleWhenStmt();
          break;
        case HTOpCode.assign:
        case HTOpCode.assignMultiply:
        case HTOpCode.assignDevide:
        case HTOpCode.assignAdd:
        case HTOpCode.assignSubtract:
          _handleAssignOp(instruction);
          break;
        case HTOpCode.logicalOr:
        case HTOpCode.logicalAnd:
        case HTOpCode.equal:
        case HTOpCode.notEqual:
        case HTOpCode.lesser:
        case HTOpCode.greater:
        case HTOpCode.lesserOrEqual:
        case HTOpCode.greaterOrEqual:
        case HTOpCode.add:
        case HTOpCode.subtract:
        case HTOpCode.multiply:
        case HTOpCode.devide:
        case HTOpCode.modulo:
          _handleBinaryOp(instruction);
          break;
        case HTOpCode.negative:
        case HTOpCode.logicalNot:
        case HTOpCode.preIncrement:
        case HTOpCode.preDecrement:
          _handleUnaryPrefixOp(instruction);
          break;
        case HTOpCode.memberGet:
        case HTOpCode.subGet:
        case HTOpCode.call:
        case HTOpCode.postIncrement:
        case HTOpCode.postDecrement:
          _handleUnaryPostfixOp(instruction);
          break;
        case HTOpCode.debugInfo:
          curLine = _bytesReader.readUint32();
          curColumn = _bytesReader.readUint32();
          curFileName = _bytesReader.readShortUtf8String();
          break;
        // 错误处理
        case HTOpCode.error:
          _handleError();
          break;
        default:
          print('Unknown opcode: $instruction');
          break;
      }

      instruction = _bytesReader.read();
    }
  }

  void _handleError() {
    final err_type = _bytesReader.read();
    // TODO: line 和 column
    switch (err_type) {
    }
  }

  void _storeLocal() {
    final valueType = _bytesReader.read();
    switch (valueType) {
      case HTValueTypeCode.NULL:
        _curValue = null;
        break;
      case HTValueTypeCode.boolean:
        (_bytesReader.read() == 0) ? _curValue = false : _curValue = true;
        break;
      case HTValueTypeCode.int64:
        final index = _bytesReader.readUint16();
        _curValue = global.getConstInt(index);
        break;
      case HTValueTypeCode.float64:
        final index = _bytesReader.readUint16();
        _curValue = global.getConstFloat(index);
        break;
      case HTValueTypeCode.utf8String:
        final index = _bytesReader.readUint16();
        _curValue = global.getConstString(index);
        break;
      case HTValueTypeCode.symbol:
        _curSymbol = _bytesReader.readShortUtf8String();
        final isMemberGet = _bytesReader.readBool();
        if (!isMemberGet) {
          _curRefType = ReferrenceType.normal;
          _curValue = curNamespace.fetch(_curSymbol!, from: curNamespace.fullName);
        } else {
          _curRefType = ReferrenceType.member;
          // 执行 member get 的时候，curValue 是 key，reg[13] 是 object
          _curValue = _curSymbol;
        }
        break;
      case HTValueTypeCode.list:
        final list = [];
        final length = _bytesReader.readUint16();
        for (var i = 0; i < length; ++i) {
          final listItem = execute();
          list.add(listItem);
        }
        _curValue = list;
        break;
      case HTValueTypeCode.map:
        final map = {};
        final length = _bytesReader.readUint16();
        for (var i = 0; i < length; ++i) {
          final key = execute();
          final value = execute();
          map[key] = value;
        }
        _curValue = map;
        break;
    }
  }

  void _storeRegister(int index, dynamic value) {
    // if (index > _register.length) {
    //   _register.length = index + 8;
    // }

    _register[index] = value;
  }

  void _assignCurRef(dynamic value) {
    switch (_curRefType) {
      case ReferrenceType.normal:
        curNamespace.assign(_curSymbol!, value);
        break;
      case ReferrenceType.member:
        final object = _register[HTRegIndex.unaryPostObject]!;
        final key = _register[HTRegIndex.unaryPostKey]!;
        // 如果是 buildin 集合
        if ((object is List) || (object is Map)) {
          object[key] = value;
        }
        // 如果是 Hetu 对象
        else if (object is HTObject) {
          object.assign(key, value, from: curNamespace.fullName);
        }
        // 如果是 Dart 对象
        else {
          var typeid = object.runtimeType.toString();
          if (typeid.contains('<')) {
            typeid = typeid.substring(0, typeid.indexOf('<'));
          }
          var externClass = fetchExternalClass(typeid);
          externClass.instanceAssign(object, key, value);
        }
        break;
    }
  }

  void _handleAssignOp(int opcode) {
    final right = _bytesReader.read();

    switch (opcode) {
      case HTOpCode.assign:
        _curValue = _register[right];
        _assignCurRef(_curValue);
        break;
      case HTOpCode.assignMultiply:
        final leftValue = _curValue;
        _curValue = leftValue * _register[right];
        _assignCurRef(_curValue);
        break;
      case HTOpCode.assignDevide:
        final leftValue = _curValue;
        _curValue = leftValue / _register[right];
        _assignCurRef(_curValue);
        break;
      case HTOpCode.assignAdd:
        final leftValue = _curValue;
        _curValue = leftValue + _register[right];
        _assignCurRef(_curValue);
        break;
      case HTOpCode.assignSubtract:
        final leftValue = _curValue;
        _curValue = leftValue - _register[right];
        _assignCurRef(_curValue);
        break;
    }
  }

  void _handleBinaryOp(int opcode) {
    final left = _bytesReader.read();
    final right = _bytesReader.read();

    switch (opcode) {
      case HTOpCode.logicalOr:
        _curValue = _register[left] = _register[left] || _register[right];
        break;
      case HTOpCode.logicalAnd:
        _curValue = _register[left] = _register[left] && _register[right];
        break;
      case HTOpCode.equal:
        _curValue = _register[left] = _register[left] == _register[right];
        break;
      case HTOpCode.notEqual:
        _curValue = _register[left] = _register[left] != _register[right];
        break;
      case HTOpCode.lesser:
        _curValue = _register[left] = _register[left] < _register[right];
        break;
      case HTOpCode.greater:
        _curValue = _register[left] = _register[left] > _register[right];
        break;
      case HTOpCode.lesserOrEqual:
        _curValue = _register[left] = _register[left] <= _register[right];
        break;
      case HTOpCode.greaterOrEqual:
        _curValue = _register[left] = _register[left] >= _register[right];
        break;
      case HTOpCode.add:
        _curValue = _register[left] = _register[left] + _register[right];
        break;
      case HTOpCode.subtract:
        _curValue = _register[left] = _register[left] - _register[right];
        break;
      case HTOpCode.multiply:
        _curValue = _register[left] = _register[left] * _register[right];
        break;
      case HTOpCode.devide:
        _curValue = _register[left] = _register[left] / _register[right];
        break;
      case HTOpCode.modulo:
        _curValue = _register[left] = _register[left] % _register[right];
        break;
      default:
      // throw HTErrorUndefinedBinaryOperator(_register[left].toString(), _register[right].toString(), opcode);
    }
  }

  void _handleUnaryPrefixOp(int op) {
    switch (op) {
      case HTOpCode.negative:
        _curValue = -_curValue;
        break;
      case HTOpCode.logicalNot:
        _curValue = !_curValue;
        break;
      case HTOpCode.preIncrement:
        _curValue = ++_curValue;
        _assignCurRef(_curValue);
        break;
      case HTOpCode.preDecrement:
        _curValue = --_curValue;
        _assignCurRef(_curValue);
        break;
      default:
      // throw HTErrorUndefinedOperator(_register[left].toString(), _register[right].toString(), HTLexicon.add);
    }
  }

  void _handleCallExpr(int regPos) {
    final callee = _register[regPos];
    var positionalArgs = [];
    final positionalArgsLength = _bytesReader.read();
    for (var i = 0; i < positionalArgsLength; ++i) {
      final arg = execute();
      positionalArgs.add(arg);
    }

    var namedArgs = <String, dynamic>{};
    final namedArgsLength = _bytesReader.read();
    for (var i = 0; i < namedArgsLength; ++i) {
      final name = _bytesReader.readShortUtf8String();
      final arg = execute();
      namedArgs[name] = arg;
    }

    // TODO: typeArgs
    var typeArgs = <HTTypeId>[];

    _curValue = call(callee, positionalArgs, namedArgs, typeArgs);
  }

  void _handleUnaryPostfixOp(int op) {
    final objIndex = _bytesReader.read();
    var object = _register[objIndex];
    final key = _curValue;

    switch (op) {
      case HTOpCode.memberGet:
        if (object is num) {
          object = HTNumber(object);
        } else if (object is bool) {
          object = HTBoolean(object);
        } else if (object is String) {
          object = HTString(object);
        } else if (object is List) {
          object = HTList(object);
        } else if (object is Map) {
          object = HTMap(object);
        }

        if ((object is HTObject)) {
          _curValue = object.fetch(key, from: curNamespace.fullName);
        }
        //如果是Dart对象
        else {
          var typeid = object.runtimeType.toString();
          if (typeid.contains('<')) {
            typeid = typeid.substring(0, typeid.indexOf('<'));
          }
          final externClass = fetchExternalClass(typeid);
          _curValue = externClass.instanceFetch(object, key);
        }
        break;
      case HTOpCode.subGet:
        if (object is List || object is Map) {
          _curValue = object[key];
        }
        throw HTErrorSubGet(object.toString());
      case HTOpCode.call:
        _handleCallExpr(objIndex);
        break;
      case HTOpCode.postIncrement:
        _curValue = _register[objIndex];
        final newValue = _register[objIndex] += 1;
        _assignCurRef(newValue);
        break;
      case HTOpCode.postDecrement:
        _curValue = _register[objIndex];
        final newValue = _register[objIndex] -= 1;
        _assignCurRef(newValue);
        break;
    }
  }

  HTTypeId _getTypeId() {
    final id = _bytesReader.readShortUtf8String();

    final length = _bytesReader.read();

    final args = <HTTypeId>[];
    for (var i = 0; i < length; ++i) {
      args.add(_getTypeId());
    }

    final isNullable = _bytesReader.read() == 0 ? false : true;

    return HTTypeId(id, isNullable: isNullable, arguments: args);
  }

  void _handleVarDecl() {
    final id = _bytesReader.readShortUtf8String();

    final isDynamic = _bytesReader.readBool();
    final isExtern = _bytesReader.readBool();
    final isImmutable = _bytesReader.readBool();
    final isMember = _bytesReader.readBool();
    final isStatic = _bytesReader.readBool();

    HTTypeId? declType;
    final hasType = _bytesReader.readBool();
    if (hasType) {
      declType = _getTypeId();
    }

    int? initializerIp;
    final hasInitializer = _bytesReader.readBool();
    if (hasInitializer) {
      final length = _bytesReader.readUint16();
      initializerIp = _bytesReader.ip;
      _bytesReader.skip(length);
    }

    final decl = HTBytesDecl(id, this,
        declType: declType,
        initializerIp: initializerIp,
        isDynamic: isDynamic,
        isExtern: isExtern,
        isImmutable: isImmutable,
        isMember: isMember,
        isStatic: isStatic);

    if (!isMember || isStatic) {
      curNamespace.define(decl);
    } else {
      (curNamespace as HTClass).defineInstance(decl);
    }
  }

  Map<String, HTBytesParamDecl> _getParams(int paramDeclsLength) {
    final paramDecls = <String, HTBytesParamDecl>{};

    for (var i = 0; i < paramDeclsLength; ++i) {
      final id = _bytesReader.readShortUtf8String();
      final isOptional = _bytesReader.readBool();
      final isNamed = _bytesReader.readBool();
      final isVariadic = _bytesReader.readBool();

      HTTypeId? declType;
      final hasType = _bytesReader.readBool();
      if (hasType) {
        declType = _getTypeId();
      }

      int? initializerIp;
      final hasInitializer = _bytesReader.readBool();
      if (hasInitializer) {
        final length = _bytesReader.readUint16();
        initializerIp = _bytesReader.ip;
        _bytesReader.skip(length);
      }

      paramDecls[id] = HTBytesParamDecl(id, this,
          declType: declType,
          initializerIp: initializerIp,
          isOptional: isOptional,
          isNamed: isNamed,
          isVariadic: isVariadic);
    }

    return paramDecls;
  }

  void _handleFuncDecl() {
    final id = _bytesReader.readShortUtf8String();

    final funcType = FunctionType.values[_bytesReader.read()];
    final isExtern = _bytesReader.readBool();
    final isStatic = _bytesReader.readBool();
    final isConst = _bytesReader.readBool();
    final isVariadic = _bytesReader.readBool();

    final minArity = _bytesReader.read();
    final maxArity = _bytesReader.read();
    final paramDecls = _getParams(_bytesReader.read());

    HTTypeId? returnType;
    final hasType = _bytesReader.readBool();
    if (hasType) {
      returnType = _getTypeId();
    }

    int? definitionIp;
    final hasDefinition = _bytesReader.readBool();
    if (hasDefinition) {
      final length = _bytesReader.readUint16();
      definitionIp = _bytesReader.ip;
      _bytesReader.skip(length);
    }

    final func = HTBytesFunction(
      id,
      this,
      className: _curClassName,
      funcType: funcType,
      paramDecls: paramDecls,
      returnType: returnType,
      definitionIp: definitionIp,
      isExtern: isExtern,
      isStatic: isStatic,
      isConst: isConst,
      isVariadic: isVariadic,
      minArity: minArity,
      maxArity: maxArity,
    );

    if (funcType == FunctionType.getter || funcType == FunctionType.setter || funcType == FunctionType.method) {
      (curNamespace as HTClass).defineInstance(HTDeclaration(id, value: func, isExtern: func.isExtern, isMember: true));
    } else {
      if (funcType != FunctionType.constructor) {
        func.context = curNamespace;
      }
      curNamespace.define(HTDeclaration(id, value: func, isExtern: func.isExtern, isMember: true));
    }
  }

  void _handleClassDecl() {
    final id = _bytesReader.readShortUtf8String();

    final classType = ClassType.values[_bytesReader.read()];

    String? superClassId;
    final hasSuperClass = _bytesReader.readBool();
    if (hasSuperClass) {
      superClassId = _bytesReader.readShortUtf8String();
    }

    HTClass? superClass;
    if (id != HTLexicon.rootClass) {
      if (superClassId == null) {
        // TODO: Object基类
        // superClass = global.fetch(HTLexicon.rootClass);
      } else {
        superClass = curNamespace.fetch(superClassId, from: curNamespace.fullName);
      }
    }

    final klass = HTClass(id, superClass, this, classType: classType, closure: curNamespace);

    // 在开头就定义类本身的名字，这样才可以在类定义体中使用类本身
    curNamespace.define(HTDeclaration(id, value: klass));

    execute(closure: klass);

    // 继承所有父类的成员变量和方法，忽略掉已经被覆盖的那些
    var curSuper = superClass;
    while (curSuper != null) {
      for (final decl in curSuper.instanceDecls.values) {
        if (decl.id.startsWith(HTLexicon.underscore)) {
          continue;
        }
        klass.defineInstance(decl.clone(), error: false);
      }

      curSuper = curSuper.superClass;
    }
  }
}
