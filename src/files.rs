use std::path::Path;

use nanocode_process_contracts::{FileHost, ProcessFuture};

pub struct NativeFiles;

impl FileHost for NativeFiles {
    fn read<'a>(&'a self, path: &'a Path) -> ProcessFuture<'a, Result<Option<String>, String>> {
        Box::pin(async move {
            match tokio::fs::read(path).await {
                Ok(bytes) => String::from_utf8(bytes)
                    .map(Some)
                    .map_err(|_| format!("{} is not UTF-8 text", path.display())),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(format!("read {}: {error}", path.display())),
            }
        })
    }

    fn write<'a>(
        &'a self,
        path: &'a Path,
        contents: &'a str,
    ) -> ProcessFuture<'a, Result<(), String>> {
        self.write_bytes(path, contents.as_bytes())
    }

    fn remove<'a>(&'a self, path: &'a Path) -> ProcessFuture<'a, Result<(), String>> {
        Box::pin(async move {
            match tokio::fs::remove_file(path).await {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(format!("remove {}: {error}", path.display())),
            }
        })
    }

    fn read_bytes<'a>(
        &'a self,
        path: &'a Path,
    ) -> ProcessFuture<'a, Result<Option<Vec<u8>>, String>> {
        Box::pin(async move {
            match tokio::fs::read(path).await {
                Ok(bytes) => Ok(Some(bytes)),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(format!("read {}: {error}", path.display())),
            }
        })
    }

    fn write_bytes<'a>(
        &'a self,
        path: &'a Path,
        bytes: &'a [u8],
    ) -> ProcessFuture<'a, Result<(), String>> {
        Box::pin(async move {
            if let Some(parent) = path.parent() {
                tokio::fs::create_dir_all(parent)
                    .await
                    .map_err(|error| format!("create {}: {error}", parent.display()))?;
            }
            tokio::fs::write(path, bytes)
                .await
                .map_err(|error| format!("write {}: {error}", path.display()))
        })
    }
}

pub fn today() -> String {
    let days = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() / 86_400);
    let (year, month, day) = civil(days as i64);
    format!("{year:04}-{month:02}-{day:02}")
}

fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}
