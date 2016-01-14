local format = string.format
local insert = table.insert

local data = require "lips.data"
local overrides = require "lips.overrides"
local Dumper = require "lips.Dumper"
local Lexer = require "lips.Lexer"

local Parser = require("lips.Class")()
function Parser:init(writer, fn, options)
    self.fn = fn or '(string)'
    self.main_fn = self.fn
    self.options = options or {}
    self.dumper = Dumper(writer, fn, options)
    self.defines = {}
end

function Parser:error(msg)
    error(format('%s:%d: Error: %s', self.fn, self.line, msg), 2)
end

function Parser:advance()
    self.i = self.i + 1
    local t = self.tokens[self.i]
    self.tt = t.tt
    self.tok = t.tok
    self.fn = t.fn
    self.line = t.line
    return t.tt, t.tok
end

function Parser:is_EOL()
    return self.tt == 'EOL' or self.tt == 'EOF'
end

function Parser:expect_EOL()
    if self:is_EOL() then
        self:advance()
        return
    end
    self:error('expected end of line')
end

function Parser:optional_comma()
    if self.tt == 'SEP' and self.tok == ',' then
        self:advance()
        return true
    end
end

function Parser:number()
    if self.tt ~= 'NUM' then
        self:error('expected number')
    end
    local value = self.tok
    self:advance()
    return value
end

function Parser:string()
    if self.tt ~= 'STRING' then
        self:error('expected string')
    end
    local value = self.tok
    self:advance()
    return value
end

function Parser:directive()
    local name = self.tok
    self:advance()
    local function add(...)
        self.dumper:add_directive(self.fn, self.line, ...)
    end
    if name == 'ORG' then
        add(name, self:number())
    elseif name == 'ALIGN' or name == 'SKIP' then
        if self:is_EOL() and name == 'ALIGN' then
            add(name, 0)
        else
            local size = self:number()
            if self:is_EOL() then
                add(name, size)
            else
                self:optional_comma()
                add(name, size, self:number())
            end
            self:expect_EOL()
        end
    elseif name == 'BYTE' or name == 'HALFWORD' then
        add(name, self:number())
        while not self:is_EOL() do
            self:advance()
            self:optional_comma()
            add(name, self:number())
        end
        self:expect_EOL()
    elseif name == 'WORD' then -- allow labels in word directives
        add(name, self:const()[2])
        while not self:is_EOL() do
            self:advance()
            self:optional_comma()
            add(name, self:const()[2])
        end
        self:expect_EOL()
    elseif name == 'INC' then
        -- noop, handled by lexer
    elseif name == 'ASCII' or name == 'ASCIIZ' then
        local bytes = self:string()
        for i, number in ipairs(bytes) do
            add('BYTE', number)
        end
        if name == 'ASCIIZ' then
            add('BYTE', 0)
        end
        self:expect_EOL()
    elseif name == 'INCBIN' then
        self:error('unimplemented')
    elseif name == 'FLOAT' then
        self:error('unimplemented')
    else
        self:error('unknown directive')
    end
end

function Parser:register(t)
    t = t or data.registers
    if self.tt ~= 'REG' then
        self:error('expected register')
    end
    local reg = self.tok
    if not t[reg] then
        self:error('wrong type of register')
    end
    self:advance()
    return reg
end

function Parser:deref()
    if self.tt ~= 'DEREF' then
        self:error('expected register to dereference')
    end
    local reg = self.tok
    self:advance()
    return reg
end

function Parser:const(relative, no_label)
    if self.tt ~= 'NUM' and self.tt ~= 'LABELSYM' then
        self:error('expected constant')
    end
    if no_label and self.tt == 'LABELSYM' then
        self:error('labels are not allowed here')
    end
    if relative and self.tt == 'LABELSYM' then
        self.tt = 'LABELREL'
    end
    local t = {self.tt, self.tok}
    self:advance()
    return t
end

function Parser:format_in(informat)
    local args = {}
    for i=1,#informat do
        local c = informat:sub(i, i)
        local c2 = informat:sub(i + 1, i + 1)
        if c == 'd' and not args.rd then
            args.rd = self:register()
        elseif c == 's' and not args.rs then
            args.rs = self:register()
        elseif c == 't' and not args.rt then
            args.rt = self:register()
        elseif c == 'D' and not args.fd then
            args.fd = self:register(data.fpu_registers)
        elseif c == 'S' and not args.fs then
            args.fs = self:register(data.fpu_registers)
        elseif c == 'T' and not args.ft then
            args.ft = self:register(data.fpu_registers)
        elseif c == 'X' and not args.rd then
            args.rd = self:register(data.sys_registers)
        elseif c == 'Y' and not args.rs then
            args.rs = self:register(data.sys_registers)
        elseif c == 'Z' and not args.rt then
            args.rt = self:register(data.sys_registers)
        elseif c == 'o' and not args.offset then
            args.offset = {'SIGNED', self:const()}
        elseif c == 'r' and not args.offset then
            args.offset = {'SIGNED', self:const('relative')}
        elseif c == 'i' and not args.immediate then
            args.immediate = self:const(nil, 'no label')
        elseif c == 'I' and not args.index then
            args.index = {'INDEX', self:const()}
        elseif c == 'k' and not args.immediate then
            args.immediate = {'NEGATE', self:const(nil, 'no label')}
        elseif c == 'K' and not args.immediate then
            args.immediate = {'SIGNED', self:const(nil, 'no label')}
        elseif c == 'b' and not args.base then
            args.base = self:deref()
        else
            error('Internal Error: invalid input formatting string', 1)
        end
        if c2:find('[dstDSTorIikKXYZ]') then
            self:optional_comma()
        end
    end
    return args
end

function Parser:format_out_raw(outformat, first, args, const, formatconst)
    local lookup = {
        [1]=self.dumper.add_instruction_j,
        [3]=self.dumper.add_instruction_i,
        [5]=self.dumper.add_instruction_r,
    }
    local out = {}
    for i=1,#outformat do
        local c = outformat:sub(i, i)
        if c == 'd' then
            out[#out+1] = args.rd
        elseif c == 's' then
            out[#out+1] = args.rs
        elseif c == 't' then
            out[#out+1] = args.rt
        elseif c == 'D' then
            out[#out+1] = args.fd
        elseif c == 'S' then
            out[#out+1] = args.fs
        elseif c == 'T' then
            out[#out+1] = args.ft
        elseif c == 'o' then
            out[#out+1] = args.offset
        elseif c == 'i' then
            out[#out+1] = args.immediate
        elseif c == 'I' then
            out[#out+1] = args.index
        elseif c == 'b' then
            out[#out+1] = args.base
        elseif c == '0' then
            out[#out+1] = 0
        elseif c == 'C' then
            out[#out+1] = const
        elseif c == 'F' then
            out[#out+1] = formatconst
        end
    end
    local f = lookup[#outformat]
    if f == nil then
        error('Internal Error: invalid output formatting string', 1)
    end
    f(self.dumper, self.fn, self.line, first, out[1], out[2], out[3], out[4], out[5])
end

function Parser:format_out(t, args)
    self:format_out_raw(t[3], t[1], args, t[4], t[5])
end

function Parser:instruction()
    local name = self.tok
    local h = data.instructions[name]
    self:advance()

    if h == nil then
        error('Internal Error: undefined instruction')
    elseif overrides[name] then
        overrides[name](self, name)
    elseif h[2] == 'tob' then -- TODO: or h[2] == 'Tob' then
        local lui = data.instructions['LUI']
        local addu = data.instructions['ADDU']
        local args = {}
        args.rt = self:register()
        self:optional_comma()
        if self.tt == 'DEREF' then
            args.offset = {'NUM', 0}
            args.base = self:deref()
        else -- NUM or LABELSYM
            local lui_args = {}
            local addu_args = {}
            local o = self:const()
            args.offset = {'LOWER', o}
            if o[1] == 'LABELSYM' or o[2] >= 0x80000000 then
                lui_args.immediate = {'UPPEROFF', o}
                lui_args.rt = 'AT'
                self:format_out(lui, lui_args)
                if not self:is_EOL() then
                    addu_args.rd = 'AT'
                    addu_args.rs = 'AT'
                    addu_args.rt = self:deref()
                    self:format_out(addu, addu_args)
                end
                args.base = 'AT'
            else
                args.base = self:deref()
            end
        end
        self:format_out(h, args)
    elseif h[2] ~= nil then
        local args = self:format_in(h[2])
        self:format_out(h, args)
    else
        self:error('unimplemented instruction')
    end
    self:expect_EOL()
end

function Parser:tokenize(asm)
    self.tokens = {}
    self.i = 0

    local routine = coroutine.create(function()
        local lexer = Lexer(asm, self.main_fn, self.options)
        lexer:lex(coroutine.yield)
    end)

    local function lex()
        local ok, a, b, c, d = coroutine.resume(routine)
        if not ok then
            a = a or 'Internal Error: lexer coroutine has stopped'
            error(a)
        end
        local t = {}
        t.tt = a
        t.tok = b
        t.fn = c
        t.line = d
        insert(self.tokens, t)
        return t.tt, t.tok, t.fn, t.line
    end

    -- first pass: collect tokens, constants, and relative labels.
    -- can't do more because instruction size can depend on a constant's size
    -- and labels depend on instruction size.
    -- note however, instruction size does not depend on label size.
    -- this would cause a recursive problem to solve,
    -- which is too much for our simple assembler.
    local plus_labels = {} -- constructed forwards
    local minus_labels = {} -- constructed backwards
    while true do
        local tt, tok, fn, line = lex()
        self.fn = fn
        self.line = line
        if tt == 'DEF' then
            local tt2, tok2 = lex()
            if tt2 ~= 'NUM' then
                self:error('expected number for define')
            end
            self.defines[tok] = tok2
        elseif tt == 'RELLABEL' then
            if tok == '+' then
                insert(plus_labels, #self.tokens)
            elseif tok == '-' then
                insert(minus_labels, 1, #self.tokens)
            else
                error('Internal Error: unexpected token for relative label', 1)
            end
        elseif tt == 'EOL' then
            -- noop
        elseif tt == 'EOF' then
            if fn == self.main_fn then
                break
            end
        elseif tt == nil then
            error('Internal Error: missing token', 1)
        end
    end

    -- resolve defines and relative labels
    for i, t in ipairs(self.tokens) do
        self.fn = t.fn
        self.line = t.line
        if t.tt == 'DEFSYM' then
            t.tt = 'NUM'
            t.tok = self.defines[t.tok]
            if t.tok == nil then
                self:error('undefined define') -- uhhh nice wording
            end
        elseif t.tt == 'RELLABEL' then
            t.tt = 'LABEL'
            -- exploits the fact that user labels can't begin with a number
            t.tok = tostring(i)
        elseif t.tt == 'RELLABELSYM' then
            t.tt = 'LABELSYM'
            local rel = t.tok
            local seen = 0
            -- TODO: don't iterate over *every* label, just the ones nearby
            if rel > 0 then
                for _, label_i in ipairs(plus_labels) do
                    if label_i > i then
                        seen = seen + 1
                        if seen == rel then
                            t.tok = tostring(label_i)
                            break
                        end
                    end
                end
            else
                for _, label_i in ipairs(minus_labels) do
                    if label_i < i then
                        seen = seen - 1
                        if seen == rel then
                            t.tok = tostring(label_i)
                            break
                        end
                    end
                end
            end
            if seen ~= rel then
                self:error('could not find appropriate relative label')
            end
        end
    end
end

function Parser:parse(asm)
    self:tokenize(asm)
    self:advance()
    while true do
        if self.tt == 'EOF' then
            if self.fn == self.main_fn then
                break
            end
            self:advance()
        elseif self.tt == 'EOL' then
            -- empty line
            self:advance()
        elseif self.tt == 'DEF' then
            self:advance()
            self:advance()
        elseif self.tt == 'DIR' then
            self:directive()
        elseif self.tt == 'LABEL' then
            self.dumper:add_label(self.tok)
            self:advance()
        elseif self.tt == 'INSTR' then
            self:instruction()
        else
            self:error('unexpected token (unknown instruction?)')
        end
    end
    return self.dumper:dump()
end

return Parser
