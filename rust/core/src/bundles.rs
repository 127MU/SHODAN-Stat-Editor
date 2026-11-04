//! Native bundle-set index and package range reads across DSAR fragments.
use crate::dsar::Dsar;
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Full,
    Light,
    Overrides,
}
impl Bundles {
    pub fn build_patch(
        &mut self,
        name: &str,
        mode: Mode,
        overrides: &BTreeMap<(u64, u64), Vec<u8>>,
    ) -> Result<crate::resource_package::Built, String> {
        let mut package = self.package(name)?;
        let mut pending = overrides
            .keys()
            .copied()
            .collect::<std::collections::BTreeSet<_>>();
        let mut blobs = Vec::new();
        for entry in &package.entries {
            let typ = u64at(entry, 8)?;
            let id = u64at(entry, 0)?;
            let key = (typ, id);
            let gpu_size = u32at(entry, 64)?;
            let stream_size = u32at(entry, 60)?;
            let heavy = gpu_size > 0 || stream_size > 0;
            let replacement = overrides.get(&key);
            if replacement.is_some() {
                pending.remove(&key);
            }
            if mode == Mode::Light && heavy {
                if replacement.is_some() {
                    return Err("轻量驻留无法覆盖带伴生数据的资源，请选择完整驻留".into());
                }
                continue;
            }
            if mode == Mode::Overrides && replacement.is_none() {
                continue;
            }
            if mode == Mode::Overrides && heavy {
                return Err("单资源覆盖含伴生数据，需要完整驻留".into());
            }
            let toc = if let Some(bytes) = replacement {
                bytes.clone()
            } else {
                self.read(name, u64at(entry, 16)?, u32at(entry, 56)? as usize)?
            };
            let mut gpu = Vec::new();
            let mut stream = Vec::new();
            if mode == Mode::Full {
                if gpu_size > 0 {
                    gpu = self.read(
                        &format!("{name}.gpu_resources"),
                        u64at(entry, 32)?,
                        gpu_size as usize,
                    )?;
                }
                if stream_size > 0 && typ != 0xe0a48d0be9a7453f && typ != 0x18dead01056b72e9 {
                    let side = format!("{name}.stream");
                    let length = self.packages.get(&side).map_or(0, |p| p.size);
                    if length > 0 {
                        let at = u64at(entry, 24)?;
                        let size = if at
                            .checked_add(stream_size as u64)
                            .is_some_and(|end| end <= length)
                        {
                            stream_size
                        } else if typ == 0xcd4238c6a0c69e32 {
                            u32at(&toc, 16)?
                        } else {
                            return Err("资源流声明大小与实际伴生文件不匹配".into());
                        };
                        stream = self.read(&side, at, size as usize)?;
                    }
                }
            }
            blobs.push(crate::resource_package::Blob {
                entry: *entry,
                toc,
                gpu,
                stream,
            });
        }
        if !pending.is_empty() {
            return Err("覆盖项含当前资源包中不存在的资源身份".into());
        }
        if mode == Mode::Overrides {
            let used = blobs
                .iter()
                .map(|b| u64at(&b.entry, 8))
                .collect::<Result<std::collections::BTreeSet<_>, _>>()?;
            package
                .types
                .retain(|row| used.contains(&u64::from_le_bytes(row[8..16].try_into().unwrap())));
        }
        package.build(&blobs)
    }
}
use std::{
    collections::{BTreeMap, VecDeque},
    fs::File,
    io::Read,
    path::{Path, PathBuf},
};
fn u32at(b: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(
        b.get(at..at + 4)
            .ok_or("资源索引字段截断")?
            .try_into()
            .unwrap(),
    ))
}
fn u64at(b: &[u8], at: usize) -> Result<u64, String> {
    Ok(u64::from_le_bytes(
        b.get(at..at + 8)
            .ok_or("资源索引字段截断")?
            .try_into()
            .unwrap(),
    ))
}
pub struct Fragment {
    pub offset: u64,
    pub uncompressed: u32,
    pub bundle: u8,
}
pub struct Package {
    pub size: u64,
    pub fragments: Vec<Fragment>,
}
pub struct Bundles {
    root: PathBuf,
    pub packages: BTreeMap<String, Package>,
    streams: BTreeMap<u8, Dsar<File>>,
    order: VecDeque<u8>,
}
impl Bundles {
    pub fn open(root: &Path) -> Result<Self, String> {
        let path = root.join("bundles.nxa");
        let mut file = File::open(&path).map_err(|_| "资源包总索引无法读取")?;
        let mut magic = [0; 4];
        file.read_exact(&mut magic)
            .map_err(|_| "资源包总索引截断")?;
        drop(file);
        let bytes = if &magic == b"DSAR" {
            let mut dsar = Dsar::open(File::open(&path).map_err(|_| "资源包总索引无法读取")?)?;
            let end = dsar
                .chunks
                .last()
                .map_or(0, |c| c.uncompressed + c.size as u64);
            if end > 256 * 1024 * 1024 {
                return Err("资源包总索引过大".into());
            }
            dsar.read_range(0, end as usize)?
        } else {
            std::fs::read(path).map_err(|_| "资源包总索引无法读取")?
        };
        Self::from_index(root, &bytes)
    }
    pub fn from_index(root: &Path, bytes: &[u8]) -> Result<Self, String> {
        let count = u32at(bytes, 16)? as usize;
        if count == 0 || count > 100000 || 24 + count * 24 > bytes.len() {
            return Err("资源包总索引目录无效".into());
        }
        let mut packages = BTreeMap::new();
        for i in 0..count {
            let at = 24 + i * 24;
            let size = u64at(bytes, at)?;
            let name = u32at(bytes, at + 8)? as usize;
            let rest = bytes.get(name..).ok_or("资源包名称越界")?;
            let end = rest
                .iter()
                .position(|b| *b == 0)
                .ok_or("资源包名称未终止")?;
            if end == 0 || end > 4096 {
                return Err("资源包名称无效".into());
            }
            let name = std::str::from_utf8(&rest[..end])
                .map_err(|_| "资源包名称编码无效")?
                .to_string();
            let n = u32at(bytes, at + 12)? as usize;
            let start = u32at(bytes, at + 16)? as usize;
            let table = bytes
                .get(
                    start
                        ..start
                            .checked_add(n.checked_mul(16).ok_or("资源分片数量溢出")?)
                            .ok_or("资源分片范围溢出")?,
                )
                .ok_or("资源分片目录截断")?;
            let mut fragments = Vec::new();
            for entry in table.chunks_exact(16) {
                let offset = u64at(entry, 0)?;
                if offset >= size && size > 0 {
                    return Err("资源分片超出包长度".into());
                }
                fragments.push(Fragment {
                    offset,
                    uncompressed: u32at(entry, 8)?,
                    bundle: entry[15],
                });
            }
            fragments.sort_by_key(|f| f.offset);
            if fragments.windows(2).any(|f| f[0].offset == f[1].offset) {
                return Err("资源分片偏移重复".into());
            }
            if packages.insert(name, Package { size, fragments }).is_some() {
                return Err("资源包名称重复".into());
            }
        }
        Ok(Self {
            root: root.to_path_buf(),
            packages,
            streams: BTreeMap::new(),
            order: VecDeque::new(),
        })
    }
    fn stream(&mut self, index: u8) -> Result<&mut Dsar<File>, String> {
        if !self.streams.contains_key(&index) {
            let source = File::open(self.root.join(format!("bundles.{index:02}.nxa")))
                .map_err(|_| "资源分包文件缺失")?;
            self.streams.insert(index, Dsar::open(source)?);
            self.order.push_back(index);
            while self.order.len() > 4 {
                if let Some(old) = self.order.pop_front() {
                    self.streams.remove(&old);
                }
            }
        }
        self.streams
            .get_mut(&index)
            .ok_or_else(|| "资源分包缓存不可用".into())
    }
    pub fn read(&mut self, name: &str, offset: u64, size: usize) -> Result<Vec<u8>, String> {
        let package = self.packages.get(name).ok_or("当前游戏中没有该资源包")?;
        let finish = offset
            .checked_add(size as u64)
            .ok_or("资源包读取范围溢出")?;
        if finish > package.size {
            return Err("资源包读取范围越界".into());
        }
        let mut plan = Vec::new();
        let mut cursor = offset;
        for (index, fragment) in package.fragments.iter().enumerate() {
            let stop = package
                .fragments
                .get(index + 1)
                .map_or(package.size, |f| f.offset);
            if stop <= offset || fragment.offset >= finish {
                continue;
            }
            let from = offset.max(fragment.offset);
            let to = finish.min(stop);
            if from != cursor {
                return Err("资源包分片存在空洞".into());
            }
            plan.push((
                fragment.bundle,
                fragment.uncompressed as u64 + from - fragment.offset,
                (to - from) as usize,
            ));
            cursor = to;
        }
        if cursor != finish {
            return Err("资源包读取内容不完整".into());
        }
        let mut out = Vec::new();
        out.try_reserve_exact(size)
            .map_err(|_| "资源包读取内存不足")?;
        for (bundle, at, n) in plan {
            out.extend(self.stream(bundle)?.read_range(at, n)?);
        }
        Ok(out)
    }
    pub fn package(&mut self, name: &str) -> Result<crate::resource_package::Package, String> {
        let head = self.read(name, 0, 72)?;
        let types = u32at(&head, 4)? as usize;
        let entries = u32at(&head, 8)? as usize;
        if types > 4096 || entries > 100000 {
            return Err("资源包目录数量异常".into());
        }
        crate::resource_package::Package::parse(&self.read(
            name,
            0,
            72 + types * 32 + entries * 80,
        )?)
    }
}
