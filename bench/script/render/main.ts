import { Chart, ChartConfiguration, ChartData } from "chart.js";
import { ChartCallback, ChartJSNodeCanvas } from "chartjs-node-canvas";
import {
  readFileSync,
  writeFileSync,
  readdirSync,
  existsSync,
  mkdirSync,
} from "fs";
import { resolve } from "path";
import { argv } from "process";

const platform = argv[2];

const inputDirPath = `../../result/json/${platform}`;

const outputDirPath = `../../result/graph/${platform}`;

if (!existsSync(outputDirPath)) {
  mkdirSync(outputDirPath, { recursive: true });
}

const actionNameMap: Record<string, string> = {
  bubble: "Bubble Sort",
  dictionary: "Map (Create & Lookup)",
  intmap: "IntMap (Create & Lookup)",
};

const languageNameMap: Record<string, string> = {
  // slow: "Neut (Slower Implementation)",
  hs: "Haskell",
  nt: "Neut",
};

interface Data {
  actionKey: string;
  languageKey: string;
  labels: Array<number>;
  data: Array<number>;
}

function getKeys(fileName: string): [string, string] {
  const basename = fileName.split(".")[0];
  const [actionKey, languageKey] = basename.split("-");
  return [actionKey, languageKey];
}

function getLabel(languageKey: string): string {
  const language = languageNameMap[languageKey];
  return `${language}`;
}

function loadData(fileDir: string, fileName: string): Data {
  var obj = JSON.parse(readFileSync(fileDir + "/" + fileName, "utf8"));
  const labels = [];
  const data = [];
  for (const result of obj["results"]) {
    const size = result["parameters"]["SIZE"];
    const mean = result["mean"];
    labels.push(size);
    data.push(mean);
  }
  const [actionKey, languageKey] = getKeys(fileName);
  return {
    actionKey: actionKey,
    languageKey: languageKey,
    labels: labels,
    data: data,
  };
}

function selectColor(languageKey: string): string {
  if (languageKey == "hs") {
    return "#8e82b2";
  } else if (languageKey == "slow") {
    return "#acac37";
  } else {
    return "#37acac";
  }
}

function asChartData(dataset: Array<Data>): ChartData {
  if (dataset.length == 0) {
    return { datasets: [] };
  } else {
    const data = dataset[0];
    const datasets = [];
    for (const data of dataset) {
      datasets.push({
        label: getLabel(data.languageKey),
        data: data.data,
        backgroundColor: [selectColor(data.languageKey)],
        borderColor: [selectColor(data.languageKey)],
        borderWidth: 4,
        fill: false,
      });
    }
    return {
      labels: data.labels,
      datasets: datasets,
    };
  }
}

const fileNameList = readdirSync(inputDirPath);

const dataset: Array<Data> = [];

for (const fileName of fileNameList) {
  const data = loadData(inputDirPath, fileName);
  dataset.push(data);
}

function filterDataSet(dataset: Array<Data>, key: string): Array<Data> {
  const list = [];
  for (const languageKey in languageNameMap) {
    for (const data of dataset) {
      if (data.actionKey == key && data.languageKey == languageKey) {
        list.push(data);
      } else {
        continue;
      }
    }
  }
  return list;
  // const result = [];
  // for (const data of dataset) {
  //   if (data["actionKey"] == key) {
  //     result.push(data);
  //   } else {
  //     continue;
  //   }
  // }
  // return result;
}

const width = 1200;
const height = 600;

for (const key in actionNameMap) {
  Chart.defaults.font.size = 16;
  const filteredDataSet = filterDataSet(dataset, key);
  const chartData = asChartData(filteredDataSet);
  const configuration: ChartConfiguration = {
    type: "line",
    data: chartData,
    options: {
      scales: {
        x: {
          title: {
            display: true,
            text: "N",
            font: {
              weight: "bold",
            },
            padding: 20,
          },
        },
        y: {
          title: {
            display: true,
            text: "Elapsed Time [s]",
            font: {
              weight: "bold",
            },
            padding: 25,
          },
        },
      },
      plugins: {
        legend: {
          position: "chartArea",
        },
        title: {
          display: true,
          text: actionNameMap[key],
        },
      },
    },
    plugins: [
      {
        id: "background-color",
        beforeDraw: (chart) => {
          const ctx = chart.ctx;
          ctx.save();
          ctx.fillStyle = "white";
          ctx.fillRect(0, 0, width, height);
          ctx.restore();
        },
      },
    ],
  };
  const chartCallback: ChartCallback = (ChartJS: any) => {
    ChartJS.defaults.font.size = 28;
    ChartJS.defaults.responsive = true;
    ChartJS.defaults.maintainAspectRatio = false;
  };
  const chartJSNodeCanvas = new ChartJSNodeCanvas({
    width,
    height,
    chartCallback,
  });

  const buffer = chartJSNodeCanvas.renderToBufferSync(configuration);
  const path = resolve(`${outputDirPath}/${key}.png`);
  writeFileSync(path, buffer, "base64");
  console.log(`wrote: ${path}`);
}
