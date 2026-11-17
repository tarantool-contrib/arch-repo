#!/usr/bin/env bash
# The test of the installed package, run by scripts/install-test.sh as an
# unprivileged user in an empty directory, with $VERSION its pkgver.
set -euo pipefail

tarantool --version
[[ $(tarantool --version | head -n 1) == "Tarantool $VERSION"* ]]

# A database, and the libraries the package links to: OpenSSL by crypto,
# ICU by the unicode collations, readline by the console.
tarantool -e "
  box.cfg{log = 'tarantool.log'}
  local s = box.schema.space.create('test')
  s:create_index('pk')
  s:create_index('name', {parts = {{2, 'string', collation = 'unicode_ci'}}})
  s:insert{1, 'Ёлка'}
  assert(s.index.name:get('ёЛКА')[1] == 1)
  assert(require('digest').sha256_hex('') ==
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
  local crypto = require('crypto')
  local key, iv = string.rep('k', 16), string.rep('i', 16)
  local secret = crypto.cipher.aes128.cbc.encrypt('text', key, iv)
  assert(crypto.cipher.aes128.cbc.decrypt(secret, key, iv) == 'text')
  assert(require('digest').base64_decode(require('digest').base64_encode('x')) == 'x')
  require('console')
  require('http.client')
  require('json')
  require('yaml')
  require('msgpack')
  box.snapshot()
  os.exit(0)
"
test -n "$(ls ./*.snap)"

# tarantoolctl and its system layout.
tarantoolctl --help > /dev/null 2>&1 || [ $? = 1 ]
getent passwd tarantool
test -f /usr/lib/systemd/system/tarantool@.service
