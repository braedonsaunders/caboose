import io
import pathlib
import tarfile
import tempfile
import unittest
import zipfile
from prepare import extract, validate

class ArchiveTests(unittest.TestCase):
    def test_paths_and_size(self):
        for name in ('../escape', '/absolute', 'x/../../escape', 'a\\b'):
            with self.assertRaises(AssertionError): validate([name], [1], 2)
        with self.assertRaises(AssertionError): validate(['ok'], [3], 2)
        with self.assertRaises(AssertionError): validate(['a', './a'], [0,0], 2)

    def test_tar_link_refused_before_any_write(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'bad.tar'; out=pathlib.Path(d)/'out'
            with tarfile.open(p,'w') as t:
                safe=tarfile.TarInfo('safe'); safe.size=1; t.addfile(safe,io.BytesIO(b'x'))
                link=tarfile.TarInfo('link'); link.type=tarfile.SYMTYPE; link.linkname='../outside'; t.addfile(link)
            with self.assertRaises(AssertionError): extract(p,out,100)
            self.assertFalse(out.exists())

    def test_zip_and_tar_regular_files(self):
        with tempfile.TemporaryDirectory() as d:
            for kind in ('zip','tar'):
                p=pathlib.Path(d)/('ok.'+kind); out=pathlib.Path(d)/kind
                if kind=='zip':
                    with zipfile.ZipFile(p,'w') as z: z.writestr('nested/file',b'data')
                else:
                    with tarfile.open(p,'w') as t:
                        m=tarfile.TarInfo('nested/file');m.size=4;t.addfile(m,io.BytesIO(b'data'))
                extract(p,out,4)
                self.assertEqual((out/'nested/file').read_bytes(),b'data')

if __name__=='__main__': unittest.main()
