part of mustache;

const Object _noSuchProperty = const Object();

final RegExp _validTag = new RegExp(r'^[0-9a-zA-Z\_\-\.]+$');
final RegExp _integerTag = new RegExp(r'^[0-9]+$');

_Node _parseTokens(List<_Token> tokens, bool lenient, String templateName) {
	var stack = new List<_Node>()..add(new _Node(_OPEN_SECTION, 'root', 0, 0));
	for (var t in tokens) {
		if (const [_TEXT, _VARIABLE, _UNESC_VARIABLE, _PARTIAL].contains(t.type)) {
			if (t.type == _VARIABLE || t.type == _UNESC_VARIABLE)
			  _checkTagChars(t, lenient, templateName);
			stack.last.children.add(new _Node.fromToken(t));

		} else if (t.type == _OPEN_SECTION || t.type == _OPEN_INV_SECTION) {
			_checkTagChars(t, lenient, templateName);
			var child = new _Node.fromToken(t);
			stack.last.children.add(child);
			stack.add(child);

		} else if (t.type == _CLOSE_SECTION) {
			_checkTagChars(t, lenient, templateName);

			if (stack.last.value != t.value) {
				throw new TemplateException(
				  "Mismatched tag, expected: '${stack.last.value}', was: '${t.value}'",
					templateName, t.line, t.column);
			}

			stack.removeLast();

		} else if (t.type == _COMMENT) {
			// Do nothing

		} else {
		  //FIXME Use switch with enums so this becomes a compile time error.
			throw new UnimplementedError();
		}
	}

	return stack.last;
}

_checkTagChars(_Token t, bool lenient, String templateName) {
		if (!lenient && !_validTag.hasMatch(t.value)) {
			throw new TemplateException(
			  'Tag contained invalid characters in name, '
				'allowed: 0-9, a-z, A-Z, underscore, and minus',
				templateName, t.line, t.column);
		}
}

_Node _parse(String source, bool lenient, String templateName) {
  var tokens = _scan(source, lenient);
  var ast = _parseTokens(tokens, lenient, templateName);
  return ast;
}


class _Template implements Template {
 
  _Template.source(String source, 
       {bool lenient: false,
        bool htmlEscapeValues : true,
        String name,
        PartialResolver partialResolver})
       :  _root = _parse(source, lenient, name),
          _lenient = lenient,
          _htmlEscapeValues = htmlEscapeValues,
          _name = name,
          _partialResolver = partialResolver;
  
  // TODO share impl with _Template.source;
  _Template.root(this._root, 
      {bool lenient: false,
       bool htmlEscapeValues : true,
       String name,
       PartialResolver partialResolver})
      :  _lenient = lenient,
         _htmlEscapeValues = htmlEscapeValues,
         _name = name,
         _partialResolver = partialResolver;
    
  final _Node _root;
  final bool _lenient;
  final bool _htmlEscapeValues;
  final String _name;
  final PartialResolver _partialResolver;
  
  String get name => _name;
  
  String renderString(values) {
    var buf = new StringBuffer();
    render(values, buf);
    return buf.toString();
  }

  void render(values, StringSink sink) {
    var renderer = new _Renderer(_root, sink, values, [values],
        _lenient, _htmlEscapeValues, _partialResolver, _name);
    renderer.render();
  }
}


class _Renderer {
  
	_Renderer(this._root,
	    this._sink,
	    this._values,
	    List stack,
	    this._lenient,
	    this._htmlEscapeValues,
	    this._partialResolver,
	    this._templateName)
    : _stack = new List.from(stack); 
	
	_Renderer.partial(_Renderer renderer, _Template partial)
      : this(partial._root,
          renderer._sink,
          renderer._values,
          renderer._stack,
          renderer._lenient,
          renderer._htmlEscapeValues,
          renderer._partialResolver,
          renderer._templateName);

	 _Renderer.subtree(_Renderer renderer, _Node node, StringSink sink)
       : this(node,
           sink,
           renderer._values,
           renderer._stack,
           renderer._lenient,
           renderer._htmlEscapeValues,
           renderer._partialResolver,
           renderer._templateName);
	
	final _Node _root;
  final StringSink _sink;
  final _values;
	final List _stack;
	final bool _lenient;
	final bool _htmlEscapeValues;
	final PartialResolver _partialResolver;
	final String _templateName;

	void render() {
		_root.children.forEach(_renderNode);
	}
	
	_write(String output) => _sink.write(output);

	_renderNode(node) {
		switch (node.type) {
			case _TEXT:
				_renderText(node);
				break;
			case _VARIABLE:
				_renderVariable(node);
				break;
			case _UNESC_VARIABLE:
				_renderVariable(node, escape: false);
				break;
			case _OPEN_SECTION:
				_renderSection(node);
				break;
			case _OPEN_INV_SECTION:
				_renderInvSection(node);
				break;
			case _PARTIAL:
			  _renderPartial(node);
			  break;
			case _COMMENT:
				break; // Do nothing.
			default:
				throw new UnimplementedError();
		}
	}

	_renderText(node) {
		_write(node.value);
	}

	// Walks up the stack looking for the variable.
	// Handles dotted names of the form "a.b.c".
	_resolveValue(String name) {
		if (name == '.') {
			return _stack.last;
		}
		var parts = name.split('.');
		var object = _noSuchProperty;
		for (var o in _stack.reversed) {
			object = _getNamedProperty(o, parts[0]);
			if (object != _noSuchProperty) {
				break;
			}
		}
		for (int i = 1; i < parts.length; i++) {
			if (object == null || object == _noSuchProperty) {
				return _noSuchProperty;
			}
			object = _getNamedProperty(object, parts[i]);
		}
		return object;
	}
	
	// Returns the property of the given object by name. For a map,
	// which contains the key name, this is object[name]. For other
	// objects, this is object.name or object.name(). If no property
	// by the given name exists, this method returns noSuchProperty.
	_getNamedProperty(object, name) {
	  
		var property = null;
		if (object is Map && object.containsKey(name))
		  return object[name];
		
		if (object is List && _integerTag.hasMatch(name))
		  return object[int.parse(name)];
		
		if (_lenient && !_validTag.hasMatch(name))
			return _noSuchProperty;
		
		var instance = reflect(object);
		var field = instance.type.instanceMembers[new Symbol(name)];
		if (field == null) return _noSuchProperty;
		
		var invocation = null;
		if ((field is VariableMirror) || ((field is MethodMirror) && (field.isGetter))) {
			invocation = instance.getField(field.simpleName);
		} else if ((field is MethodMirror) && (field.parameters.length == 0)) {
			invocation = instance.invoke(field.simpleName, []);
		}
		if (invocation == null) {
			return _noSuchProperty;
		}
		return invocation.reflectee;
	}

	_renderVariable(node, {bool escape : true}) {
		var value = _resolveValue(node.value);
		
		if (value is Function) value = value('');
		
		if (value == _noSuchProperty) {
			if (!_lenient)
				throw new TemplateException(
				  'Value was missing, variable: ${node.value}',
					_templateName, node.line, node.column);
		} else {
			var valueString = (value == null) ? '' : value.toString();
			var output = !escape || !_htmlEscapeValues
				? valueString
				: _htmlEscape(valueString);
			_write(output);
		}
	}

	_renderSectionWithValue(node, value) {
		_stack.add(value);
		node.children.forEach(_renderNode);
		_stack.removeLast();
	}

	String _renderSubtree(node) {
	  var sink = new StringBuffer();
	  var renderer = new _Renderer.subtree(this, node, sink);
	  renderer.render();
	  return sink.toString();
	}
	
	_renderSection(node) {
		var value = _resolveValue(node.value);
    
		if (value == null) {
			// Do nothing.
		
		} else if (value is Iterable) {
			value.forEach((v) => _renderSectionWithValue(node, v));
		
		} else if (value is Map) {
			_renderSectionWithValue(node, value);
		
		} else if (value == true) {
			_renderSectionWithValue(node, value);
		
		} else if (value == false) {
			// Do nothing.
		
		} else if (value == _noSuchProperty) {
			if (!_lenient)
				throw new TemplateException(
				  'Value was missing, section: ${node.value}',
					_templateName, node.line, node.column);
		
		} else if (value is Function) {
         var output = _renderSubtree(node);
         _write(value(output));
		
		} else {
			throw new TemplateException(
			  'Invalid value type for section, '
				'section: ${node.value}, '
        'type: ${value.runtimeType}',
				_templateName, node.line, node.column);
		}
	}

	_renderInvSection(node) {
		var value = _resolveValue(node.value);
    
		if (value == null) {
			_renderSectionWithValue(node, null);
		
		} else if ((value is Iterable && value.isEmpty) || value == false) {
			_renderSectionWithValue(node, value);
		
		} else if (value == true || value is Map || value is Iterable) {
			// Do nothing.
		
		} else if (value == _noSuchProperty) {
			if (_lenient) {
				_renderSectionWithValue(node, null);
			} else {
				throw new TemplateException(
				    'Value was missing, inverse-section: ${node.value}',
				    _templateName, node.line, node.column);
			}
    
		} else if (value is Function) {
      var output = _renderSubtree(node);
      if (value(output) != false) {
        // FIXME not sure what to output here, result of function or template 
        // output?
        _write(output);
      }

		} else {
			throw new TemplateException(
			  'Invalid value type for inverse section, '
				'section: ${node.value}, '
				'type: ${value.runtimeType}, ',
				_templateName, node.line, node.column);
		}
	}

  _renderPartial(_Node node) {
    var partialName = node.value;
    _Template template = _partialResolver(partialName);
    if (template != null) {
      var renderer = new _Renderer.partial(this, template);
      renderer.render();      
    } else if (_lenient) {
      // do nothing
    } else {
      throw new TemplateException(
          'Partial not found: $partialName',
          _templateName, node.line, node.column);
    }
  }

  static const Map<String,String> _htmlEscapeMap = const {
    _AMP: '&amp;',
    _LT: '&lt;',
    _GT: '&gt;',
    _QUOTE: '&quot;',
    _APOS: '&#x27;',
    _FORWARD_SLASH: '&#x2F;' 
  };
  
	String _htmlEscape(String s) {
	  
		var buffer = new StringBuffer();
		int startIndex = 0;
		int i = 0;
		for (int c in s.runes) {
			if (c == _AMP
					|| c == _LT
					|| c == _GT
					|| c == _QUOTE
					|| c == _APOS
					|| c == _FORWARD_SLASH) {
				buffer.write(s.substring(startIndex, i));
				buffer.write(_htmlEscapeMap[c]);
				startIndex = i + 1;
			}
			i++;
		}
		buffer.write(s.substring(startIndex));
		return buffer.toString();
	}
}

_visit(_Node root, visitor(_Node n)) {
	var _stack = new List<_Node>()..add(root);
	while (!_stack.isEmpty) {
		var node = _stack.removeLast();
		_stack.addAll(node.children);
		visitor(node);
	}
}

class _Node {
	_Node(this.type, this.value, this.line, this.column);
	_Node.fromToken(_Token token)
		: type = token.type,
			value = token.value,
			line = token.line,
			column = token.column;
	final int type;
	final String value;
	final int line;
	final int column;
	final List<_Node> children = new List<_Node>();
	String toString() => '_Node: ${_tokenTypeString(type)}';
}
