<?php

declare(strict_types=1);

use pmmp\thread\Worker;

if(PHP_VERSION_ID < 80400 || !PHP_ZTS || !extension_loaded('pmmpthread')){
	throw new RuntimeException('PHP 8.4 ZTS with pmmpthread is required');
}

function median(array $values): float{
	sort($values, SORT_NUMERIC);
	return $values[intdiv(count($values), 2)];
}

function elapsed(callable $work): float{
	$start = hrtime(true);
	$work();
	return (hrtime(true) - $start) / 1_000_000_000;
}

$startup = [];
$cpu = [];
$threads = [];
$memory = memory_get_usage(true);

for($sample = 0; $sample < 7; ++$sample){
	$startup[] = elapsed(static function(): void{
		$process = proc_open([PHP_BINARY, '-c', dirname(PHP_BINARY) . '/php.ini', '-d', 'extension_dir=' . ini_get('extension_dir'), '-r', 'exit(0);'], [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
		if(!is_resource($process)){
			throw new RuntimeException('Could not start child PHP');
		}
		foreach($pipes as $pipe){
			fclose($pipe);
		}
		if(proc_close($process) !== 0){
			throw new RuntimeException('Child PHP failed');
		}
	});
}

for($sample = 0; $sample < 7; ++$sample){
	$cpu[] = elapsed(static function(): void{
		$sum = 0;
		for($i = 0; $i < 1_000_000; ++$i){
			$sum = ($sum + ($i * 17)) % 1_000_003;
		}
		if($sum !== 102){
			throw new RuntimeException("CPU workload changed: $sum");
		}
	});
	$threads[] = elapsed(static function(): void{
		for($i = 0; $i < 8; ++$i){
			$worker = new Worker();
			if(!$worker->start() || !$worker->shutdown()){
				throw new RuntimeException('Worker failed');
			}
		}
	});
}

echo json_encode([
	'php' => PHP_VERSION,
	'os' => PHP_OS_FAMILY,
	'arch' => php_uname('m'),
	'samples' => 7,
	'cpu_iterations' => 1_000_000,
	'workers_per_sample' => 8,
	'startup_ms_median' => round(median($startup) * 1000, 3),
	'memory_start_bytes' => $memory,
	'memory_peak_bytes' => memory_get_peak_usage(true),
	'cpu_iterations_per_second_median' => round(1_000_000 / median($cpu)),
	'worker_start_shutdown_ms_median' => round(median($threads) * 1000 / 8, 3),
], JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), "\n";
