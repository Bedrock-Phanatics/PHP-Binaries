<?php

declare(strict_types=1);

use pmmp\thread\Runnable;
use pmmp\thread\Thread;
use pmmp\thread\ThreadSafe;
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
	'Zend OPcache', 'libdeflate', 'snappy', 'xxhash', 'fileinfo', 'gd', 'mysqli', 'recursionguard',
] as $extension){
	check(extension_loaded($extension), "$extension is missing");
}
if(PHP_OS_FAMILY === 'Windows'){
	check(extension_loaded('sqlite3'), 'sqlite3 is missing');
}

check(ini_get('opcache.enable_cli') === '1', 'OPcache is disabled for CLI');
check(is_array(opcache_get_status(false)), 'OPcache failed to initialize');
check(curl_init() instanceof CurlHandle, 'curl failed to initialize');
check(Thread::getRunningCount() === 0, 'Threads are running before the test');

final class Counter extends ThreadSafe{
	public int $value = 0;
}

final class CountThread extends Thread{
	public function __construct(private Counter $counter){}

	public function run(): void{
		$this->counter->synchronized(function(): void{
			++$this->counter->value;
		});
	}
}

final class CountTask extends Runnable{
	public function __construct(private Counter $counter){}

	public function run(): void{
		$this->counter->synchronized(function(): void{
			++$this->counter->value;
		});
	}
}

$counter = new Counter();
for($round = 0; $round < 4; ++$round){
	$threads = [];
	for($i = 0; $i < 4; ++$i){
		$thread = new CountThread($counter);
		check($thread->start(), 'Thread creation failed');
		$threads[] = $thread;
	}
	foreach($threads as $thread){
		check($thread->join() && $thread->isJoined() && !$thread->isTerminated(), 'Thread did not finish cleanly');
	}
	check(Thread::getRunningCount() === 0, 'Thread leaked after join');
}

$workers = [];
for($i = 0; $i < 4; ++$i){
	$worker = new Worker();
	check($worker->start(), 'Worker creation failed');
	for($task = 0; $task < 8; ++$task){
		check($worker->stack(new CountTask($counter)) > 0, 'Worker task was not queued');
	}
	$workers[] = $worker;
}
foreach($workers as $worker){
	check($worker->shutdown() && $worker->isShutdown() && !$worker->isTerminated(), 'Worker did not shut down cleanly');
}
check($counter->value === 48, "Synchronization failed: got $counter->value, expected 48");
check(Thread::getRunningCount() === 0, 'Worker leaked after shutdown');

echo "PHP ", PHP_VERSION, " ZTS, extensions, OPcache, threads and workers OK\n";
