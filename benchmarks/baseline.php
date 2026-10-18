<?php

declare(strict_types=1);

use pmmp\thread\Worker;
use pmmp\thread\Runnable;
use pmmp\thread\ThreadSafe;

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

final class Counter extends ThreadSafe{
	public int $value = 0;
}

final class IncrementTask extends Runnable{
	public function __construct(private Counter $counter){}

	public function run(): void{
		$this->counter->synchronized(function(): void{
			++$this->counter->value;
		});
	}
}

$startup = [];
$cpu = [];
$threads = [];
$workerTasks = [];
$allocations = [];
$memory = memory_get_usage(true);

fwrite(STDERR, "startup\n");
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

fwrite(STDERR, "runtime samples\n");
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
			if(!$worker->start(0) || !$worker->shutdown()){
				throw new RuntimeException('Worker failed');
			}
		}
	});
	fwrite(STDERR, "worker tasks $sample\n");
	$workerTasks[] = elapsed(static function(): void{
		$counter = new Counter();
		$workers = [];
		for($i = 0; $i < 4; ++$i){
			$worker = new Worker();
			if(!$worker->start(0)){
				throw new RuntimeException('Worker failed to start');
			}
			for($task = 0; $task < 64; ++$task){
				$worker->stack(new IncrementTask($counter));
			}
			$workers[] = $worker;
		}
		foreach($workers as $worker){
			$worker->synchronized(static function() use ($worker): void{
				while($worker->collect() > 0){
					$worker->wait();
				}
			});
			if(!$worker->shutdown()){
				throw new RuntimeException('Worker failed to shut down');
			}
		}
		if($counter->value !== 256){
			throw new RuntimeException('Worker tasks were lost');
		}
	});
	fwrite(STDERR, "allocations $sample\n");
	$allocations[] = elapsed(static function(): void{
		for($round = 0; $round < 512; ++$round){
			$blocks = [];
			for($i = 0; $i < 256; ++$i){
				$blocks[] = str_repeat('x', 64 + (($round * 131 + $i * 17) % 2048));
			}
			unset($blocks);
		}
		gc_collect_cycles();
	});
}

$rss = getrusage();
$opcache = opcache_get_status(false);

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
	'memory_after_churn_bytes' => memory_get_usage(true),
	'peak_rss_bytes' => ($rss['ru_maxrss'] ?? 0) * 1024,
	'opcache_jit_buffer_bytes' => $opcache['jit']['buffer_size'] ?? 0,
	'cpu_iterations_per_second_median' => round(1_000_000 / median($cpu)),
	'worker_start_shutdown_ms_median' => round(median($threads) * 1000 / 8, 3),
	'worker_tasks_per_second_median' => round(256 / median($workerTasks)),
	'allocation_churn_ms_median' => round(median($allocations) * 1000, 3),
], JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), "\n";
