import { describe, expect, test } from 'claude-code/testing'
import { codeVerdict } from '../hooks/code.ts'

// The per language judge of inline code (#712: moved here from scope-modes, so $.modkit.writes and
// no build read code the same way). Its rules are pinned end to end through no build's own tests;
// these are the ones #730 changed.
describe('codeVerdict after #730', () => {
  // The rule naming a builtin to send or method had no trailing boundary, so a method merely
  // starting with one was refused as running a process.
  test("ruby's send and method name a builtin only when the whole name is one", () => {
    expect(codeVerdict('ruby', 'conn.send(:execute, sql)')).toBeUndefined()
    expect(codeVerdict('ruby', 'h = method(:fork_helper)')).toBeUndefined()
    expect(codeVerdict('ruby', 'send(:spawn_worker)')).toBeUndefined()
    expect(codeVerdict('ruby', 'obj.public_send(:system?)')).toBeUndefined()
    expect(codeVerdict('ruby', '"".send(:system, "ls")')).toEqual({ does: 'run a process', seen: 'system' })
    expect(codeVerdict('ruby', 'send(:exec, "ls")')).toEqual({ does: 'run a process', seen: 'exec' })
    expect(codeVerdict('ruby', 'send("`", "ls")')).toEqual({ does: 'run a process', seen: 'backticks' })
  })
  test('a send of a name built at run time still cannot be read', () => {
    expect(codeVerdict('ruby', 'send(name, "ls")')).toEqual({ does: 'unreadable', seen: 'send of a computed name' })
    expect(codeVerdict('ruby', 'send("sys" + "tem", "ls")')).toEqual({ does: 'unreadable', seen: 'send of a computed name' })
  })
  test("python's fileinput rewrites its files in place when inplace is set", () => {
    expect(codeVerdict('python', "import fileinput\nfor l in fileinput.input('a.txt', inplace=True): print(l)")).toEqual({ does: 'write files', seen: 'fileinput with inplace' })
    expect(codeVerdict('python', "import fileinput; fileinput.FileInput(files=['a'], inplace=1)")).toEqual({ does: 'write files', seen: 'fileinput with inplace' })
    expect(codeVerdict('python', "from fileinput import input\nfor l in input('a', inplace=True): pass")).toEqual({ does: 'write files', seen: 'fileinput with inplace' })
    expect(codeVerdict('python', "import fileinput\nfor l in fileinput.input('a.txt'): print(l)")).toBeUndefined()
    expect(codeVerdict('python', "import fileinput\nfor l in fileinput.input('a.txt', inplace=False): print(l)")).toBeUndefined()
  })
  test("pathlib's rename and replace move a file; str.replace and a data frame's rename do not", () => {
    expect(codeVerdict('python', "from pathlib import Path; Path('a').rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "from pathlib import Path; p = Path('a'); p.replace(target)")).toEqual({ does: 'write files', seen: 'replace' })
    expect(codeVerdict('python', "print('abc'.replace('a', 'b'))")).toBeUndefined()
    expect(codeVerdict('python', "s = name.replace('x', '', 1)")).toBeUndefined()
    expect(codeVerdict('python', "df = df.rename(columns={'a': 'b'})")).toBeUndefined()
    expect(codeVerdict('python', "df.replace({'a': 'b'})")).toBeUndefined()
    expect(codeVerdict('python', 'df.rename(str.lower, axis=1)')).toBeUndefined()
  })
})

// #760 items 5, decided by Dan on 2026-10-05: two false refusals stop, the real routes stay refused.
describe('codeVerdict after #760', () => {
  test("a pandas Series.rename with one name is no move; a pathlib rename still is", () => {
    expect(codeVerdict('python', "import pandas as pd\ns = pd.Series([1, 2])\ns = s.rename('total')")).toBeUndefined()
    expect(codeVerdict('python', "import pandas as pd\ndf = pd.read_csv('a.csv')\ndf['x'].replace('a')")).toBeUndefined()
    expect(codeVerdict('python', "from pandas import Series\ns = Series([1])\ns = s.rename('t')")).toBeUndefined()
    // Bound through another pandas object.
    expect(codeVerdict('python', "import pandas as pd\ndf = pd.DataFrame()\ns = df['x']\ns.rename('t')")).toBeUndefined()
    // pandas named anywhere in an import list is still pandas.
    expect(codeVerdict('python', "import os, pandas\ns = pandas.Series([1])\ns.rename('total')")).toBeUndefined()
    expect(codeVerdict('python', "import numpy as np, pandas as pd\ns = pd.Series([1])\ns.rename('total')")).toBeUndefined()
    // Only a receiver bound from pandas is exempt: pandas being imported says nothing about any
    // other object (lessons review of #818).
    expect(codeVerdict('python', "import pandas\nimport py\npy.path.local('a').rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pandas as pd\nsftp.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "x = 'import pandas'\nf.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    // A name bound from pandas and then rebound to anything else, or bound by any other route (a
    // loop, a with, a parameter, a tuple, :=), is no longer proved pandas (lessons review of #818).
    expect(codeVerdict('python', "import pandas as pd\nfrom pathlib import Path\ndf = pd.read_csv('a.csv')\ndf = Path('a')\ndf.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pandas as pd\ndf = pd.DataFrame()\ndf = 'a.txt'\ndf.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pandas as pd\ndf = pd.DataFrame()\nfor df in paths:\n    df.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pandas as pd\ndf = pd.DataFrame()\nwith open('x') as df:\n    df.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pandas as pd\ndf = pd.DataFrame()\ndef f(df):\n    df.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pandas as pd\ndf = pd.DataFrame()\nx, df = 1, p\ndf.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pandas as pd\ndf = pd.DataFrame()\nif (df := p):\n    df.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    // An attribute of another object that shares a pandas name is not that name.
    expect(codeVerdict('python', "import pandas as pd\ndf = pd.DataFrame()\nobj.df.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    // A right hand side that is more than a pandas chain proves nothing.
    expect(codeVerdict('python', "import pandas as pd\nfrom pathlib import Path\ndf = pd or Path('a')\ndf.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pandas as pd\nfrom pathlib import Path\ndf = pd.read_csv(x) if y else Path('a')\ndf.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    // An assignment anywhere else in a statement (after a header's colon, say) rebinds too.
    expect(codeVerdict('python', "import pandas as pd\nfrom pathlib import Path\ndf = pd.DataFrame()\nif 1: df = Path('a')\ndf.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pandas as pd\nfrom pathlib import Path\ndf = pd.DataFrame()\ntry: df = Path('a')\nexcept E: pass\ndf.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    // pandas itself, or any name it was imported as, rebound to something else is no longer pandas.
    expect(codeVerdict('python', "import pandas\nfrom pathlib import Path\npandas = Path('a')\npandas.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pandas as pd\nfrom pathlib import Path\npd = Path('a')\npd.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pandas as pd\nfor pd in paths:\n    pd.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "from pandas import Series\nfrom pathlib import Path\nSeries = Path\ns = Series('a')\ns.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    // A chained assignment binds every target in it, not only the first.
    expect(codeVerdict('python', "import pandas as pd\nfrom pathlib import Path\ndf = pd.DataFrame()\nx = df = Path('a')\ndf.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    // An annotated assignment is a rebinding too.
    expect(codeVerdict('python', "import pandas as pd\nfrom pathlib import Path\ndf = pd.DataFrame()\ndf: Path = Path('a')\ndf.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    // Rebound only from pandas, it is still pandas.
    expect(codeVerdict('python', "import pandas as pd\ndf = pd.DataFrame()\ndf = df.dropna()\ndf.rename('t')")).toBeUndefined()
    // A chained call has no bound name to prove pandas by, so it is still read as a move (accepted,
    // since it errs toward refusing; bind the result to a name to run it).
    expect(codeVerdict('python', "import pandas as pd\npd.Series([1]).rename('t')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "from pathlib import Path\nPath('a').rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pathlib\npathlib.Path('a').replace('b')")).toEqual({ does: 'write files', seen: 'replace' })
    // pandas and pathlib in one script: which receiver is which cannot be told, so it is a move.
    expect(codeVerdict('python', "import pandas as pd\nfrom pathlib import Path\np = Path('a')\np.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    // Neither imported: the receiver is unknown, so it is still read as a move.
    expect(codeVerdict('python', "x.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    // os.rename is its own rule and is untouched by pandas being imported.
    expect(codeVerdict('python', "import pandas as pd\nimport os\nos.rename('a', 'b')")).toEqual({ does: 'write files', seen: 'os.rename' })
  })
  test("ruby's def send(x) defines a method; a send of a computed name is still unreadable", () => {
    expect(codeVerdict('ruby', 'class Mailer\n  def send(x)\n    deliver(x)\n  end\nend')).toBeUndefined()
    expect(codeVerdict('ruby', 'def self.send(msg) = puts(msg)')).toBeUndefined()
    expect(codeVerdict('ruby', 'def public_send(name, *args); end')).toBeUndefined()
    expect(codeVerdict('ruby', 'send(name, "ls")')).toEqual({ does: 'unreadable', seen: 'send of a computed name' })
    expect(codeVerdict('ruby', 'def go(n)\n  send(n)\nend')).toEqual({ does: 'unreadable', seen: 'send of a computed name' })
  })
})
