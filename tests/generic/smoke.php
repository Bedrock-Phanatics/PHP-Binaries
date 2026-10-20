<?php

declare(strict_types=1);

use pmmp\thread\Runnable;
use pmmp\thread\Thread;
use pmmp\thread\ThreadSafe;
use pmmp\thread\ThreadSafeQueue;
use pmmp\thread\Worker;

function check(bool $condition, string $message): void{
	if(!$condition){
		throw new RuntimeException($message);
	}
}

check(PHP_SAPI === 'cli', 'CLI SAPI required');
check(PHP_VERSION_ID >= 80400, 'PHP 8.4 or newer required');
check(PHP_INT_SIZE === 8, '64-bit PHP required');
check(PHP_ZTS, 'ZTS required');
check(php_ini_loaded_file() !== false, 'php.ini was not loaded');

foreach([
	'chunkutils2', 'crypto', 'ctype', 'curl', 'date', 'encoding', 'gmp', 'hash',
	'igbinary', 'json', 'leveldb', 'mbstring', 'morton', 'openssl', 'pcre', 'Phar',
	'pmmpthread', 'Reflection', 'SimpleXML', 'sockets', 'SPL', 'yaml', 'zip', 'zlib',
	'Zend OPcache', 'libdeflate', 'snappy', 'xxhash', 'fileinfo', 'gd', 'mysqli', 'recursionguard', 'toml',
] as $extension){
	check(extension_loaded($extension), "$extension is missing");
}
if(PHP_OS_FAMILY === 'Windows'){
	check(extension_loaded('sqlite3'), 'sqlite3 is missing');
}
check((new ReflectionExtension('pmmpthread'))->getVersion() === '6.4.0', 'qthreads version mismatch');
check(class_exists(ThreadSafeQueue::class), 'qthreads queue is missing');

check(ini_get('opcache.enable_cli') === '1', 'OPcache is disabled for CLI');
$opcache = opcache_get_status(false);
check(is_array($opcache) && $opcache['opcache_enabled'], 'OPcache failed to initialize');
check(!($opcache['jit']['enabled'] ?? false) && ($opcache['jit']['buffer_size'] ?? 0) === 0, 'JIT memory is allocated');
check(curl_init() instanceof CurlHandle, 'curl failed to initialize');
check(version_compare(curl_version()['version'], '8.23.0', '>='), 'libcurl is outdated');
check(OPENSSL_VERSION_NUMBER >= 0x30500090, 'OpenSSL is outdated');
check(toml_parse("port = 19132\n[[worlds]]\nname = \"world\"") === ['port' => 19132, 'worlds' => [['name' => 'world']]], 'toml_parse failed');
try{
	toml_parse('port = ');
	check(false, 'toml_parse accepted invalid TOML');
}catch(TomlParseException $e){
	check($e->getTomlLine() === 1, 'toml_parse reported the wrong error location');
}
check(Thread::getRunningCount() === 0, 'Threads are running before the test');

final class Counter extends ThreadSafe{
	public int $value = 0;
}

final class CountThread extends Thread{
	public function __construct(private Counter $counter, private ThreadSafeQueue $queue){}

	public function run(): void{
		$status = opcache_get_status(false);
		if(!is_array($status) || !$status['opcache_enabled'] || ($status['jit']['buffer_size'] ?? 0) !== 0){
			throw new RuntimeException('OPcache failed in a thread');
		}
		if(toml_parse('value = 1') !== ['value' => 1]){
			throw new RuntimeException('toml_parse failed in a thread');
		}
		$this->queue->push('thread');
		// Resolve the shared object before taking its lock.
		$counter = $this->counter;
		$counter->synchronized(static function() use ($counter): void{
			++$counter->value;
		});
	}
}

final class CountTask extends Runnable{
	public function __construct(private Counter $counter, private ThreadSafeQueue $queue){}

	public function run(): void{
		$status = opcache_get_status(false);
		if(!is_array($status) || !$status['opcache_enabled'] || ($status['jit']['buffer_size'] ?? 0) !== 0){
			throw new RuntimeException('OPcache failed in a worker');
		}
		$this->queue->push('worker');
		$counter = $this->counter;
		$counter->synchronized(static function() use ($counter): void{
			++$counter->value;
		});
	}
}

$counter = new Counter();
$queue = new ThreadSafeQueue();
for($round = 0; $round < 4; ++$round){
	$threads = [];
	for($i = 0; $i < 4; ++$i){
		$thread = new CountThread($counter, $queue);
		check($thread->start(0), 'Thread creation failed');
		$threads[] = $thread;
	}
	foreach($threads as $thread){
		check($thread->join() && $thread->isJoined() && !$thread->isTerminated(), 'Thread did not finish cleanly');
	}
	check(Thread::getRunningCount() === 0, 'Thread leaked after join');
}

for($round = 0; $round < 8; ++$round){
	$workers = [];
	for($i = 0; $i < 4; ++$i){
		$worker = new Worker();
		check($worker->start(0), 'Worker creation failed');
		for($task = 0; $task < 8; ++$task){
			check($worker->stack(new CountTask($counter, $queue)) > 0, 'Worker task was not queued');
		}
		$workers[] = $worker;
	}
	foreach($workers as $worker){
		$worker->synchronized(static function() use ($worker): void{
			while($worker->collect() > 0){
				$worker->wait();
			}
		});
		check($worker->shutdown() && $worker->isShutdown() && !$worker->isTerminated(), 'Worker did not shut down cleanly');
	}
	check(Thread::getRunningCount() === 0, 'Worker leaked after shutdown');
}
check($counter->value === 272, "Synchronization failed: got $counter->value, expected 272");
$transfers = ['thread' => 0, 'worker' => 0];
for($i = 0; $i < 272; ++$i){
	$value = $queue->pop(0);
	check(isset($transfers[$value]), 'Invalid cross-thread transfer');
	++$transfers[$value];
}
check($transfers === ['thread' => 16, 'worker' => 256], 'Cross-thread transfers were lost');
$queue->close();
check($queue->isClosed() && $queue->pop(0) === null, 'Queue did not close cleanly');

echo "PHP ", PHP_VERSION, " ZTS, extensions, OPcache, TOML, threads, workers and qthreads queue OK\n";
